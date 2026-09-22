import Foundation
import Network
import AppKit

/// Serves the iPhone/iPad app over the local network. Only runs once a pairing key exists.
/// See `Remote` for the security model: every body is sealed with the shared key, stale or
/// repeated requests are refused, and nothing the phone sends is run as a command; it can only
/// do what the Mac app's own buttons do (send a text, rename, pin, stop, group).
@MainActor
final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()

    @Published private(set) var running = false
    @Published private(set) var lastClient: String?
    @Published private(set) var lastSeen: Date?

    private weak var store: Store?
    private var listener: NWListener?
    private var key: Data?
    private var seenNonces: [String: TimeInterval] = [:]
    private var failures: [String: [TimeInterval]] = [:]

    private static let keyURL: URL = Store.fileURL.deletingLastPathComponent().appendingPathComponent("remote-key")

    var isPaired: Bool { key != nil }

    func attach(_ store: Store) {
        self.store = store
        key = try? Data(contentsOf: Self.keyURL)
        if key?.count != 32 { key = nil }
        if key != nil { start() }
    }

    /// Makes (or remakes) the pairing key. Remaking it disconnects every phone paired before.
    func newPairing() {
        let k = Seal.newKey()
        do {
            try k.write(to: Self.keyURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.keyURL.path)
            key = k
            seenNonces = [:]
            Log.info("remote: new pairing key")
            start()
        } catch { Log.error("remote: couldn't save key: \(error)") }
    }

    func unpair() {
        try? FileManager.default.removeItem(at: Self.keyURL)
        key = nil
        listener?.cancel(); listener = nil; running = false
        Log.info("remote: unpaired, server off")
    }

    var pairing: PairingInfo? {
        guard let key else { return nil }
        return PairingInfo(key: key, hosts: Self.localHosts(), port: Remote.port, macName: Host.current().localizedName ?? "Mac")
    }

    /// LAN addresses first, then the Bonjour name, so the phone has something to try at home.
    static func localHosts() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let flags = Int32(p.pointee.ifa_flags)
                guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                      flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254") && !out.contains(ip) { out.append(ip) }
                }
            }
            freeifaddrs(ifaddr)
        }
        if let local = ProcessInfo.processInfo.hostName.split(separator: ".").first {
            out.append("\(local).local")
        }
        return out
    }

    // MARK: Listener

    private func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Remote.port)!)
            l.service = NWListener.Service(name: Host.current().localizedName, type: Remote.bonjourType)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.running = true; Log.info("remote: listening on \(Remote.port)")
                    case .failed(let e): self?.running = false; self?.listener = nil; Log.error("remote: listener failed \(e)")
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch { Log.error("remote: couldn't start: \(error)") }
    }

    private func accept(_ conn: NWConnection) {
        let peer: String = {
            if case .hostPort(let h, _) = conn.endpoint { return "\(h)" }
            return "\(conn.endpoint)"
        }()
        if tooManyFailures(peer) { conn.cancel(); return }
        conn.start(queue: .main)
        receive(conn, peer: peer, buffer: Data())
    }

    /// Reads one small HTTP request (headers + Content-Length body), handles it, answers, closes.
    private func receive(_ conn: NWConnection, peer: String, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if buf.count > 2 * 1024 * 1024 || error != nil { conn.cancel(); return }
                guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if done { conn.cancel() } else { self.receive(conn, peer: peer, buffer: buf) }
                    return
                }
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }.first ?? 0
                let body = buf[headerEnd.upperBound...]
                if body.count < length {
                    if done { conn.cancel() } else { self.receive(conn, peer: peer, buffer: buf) }
                    return
                }
                guard head.hasPrefix("POST /rpc ") else { self.reply(conn, status: 404, body: Data()); return }
                let (status, out) = await self.handle(Data(body.prefix(length)), peer: peer)
                self.reply(conn, status: status, body: out)
            }
        }
    }

    private func reply(_ conn: NWConnection, status: Int, body: Data) {
        let reason = [200: "OK", 401: "Unauthorized", 404: "Not Found"][status] ?? "Error"
        var d = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        d.append(body)
        conn.send(content: d, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: Requests

    private func handle(_ body: Data, peer: String) async -> (Int, Data) {
        guard let key, let store else { return (401, Data()) }
        guard let req = try? Seal.open(RPCRequest.self, from: body, key: key) else {
            noteFailure(peer)
            Log.error("remote: rejected unreadable request from \(peer)")
            return (401, Data())
        }
        let now = Date().timeIntervalSince1970
        seenNonces = seenNonces.filter { now - $0.value < Remote.maxClockSkew * 2 }
        guard abs(now - req.ts) < Remote.maxClockSkew, seenNonces[req.nonce] == nil else {
            noteFailure(peer)
            Log.error("remote: rejected stale or repeated request from \(peer)")
            return (401, Data())
        }
        seenNonces[req.nonce] = now
        lastClient = peer
        lastSeen = Date()

        var res = RPCResponse(nonce: req.nonce, ok: true)
        switch req.op {
        case .sync:
            let since = req.since ?? -1
            let deadline = Date().addingTimeInterval(Remote.longPollSeconds)
            while store.version <= since && Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            res.snapshot = snapshot(store)
        case .send:
            if let c = req.conv, let t = req.text { store.send(t, in: c) } else { res.ok = false }
        case .rename:
            if let c = req.conv { store.rename(c, to: req.text ?? "") } else { res.ok = false }
        case .pin:
            if let c = req.conv { store.togglePin(c) } else { res.ok = false }
        case .stop:
            if let c = req.conv { store.stop(c); store.save() } else { res.ok = false }
        case .markRead:
            if let c = req.conv { store.markRead(c) }
        case .hide:
            if let c = req.conv { store.hide(c) }
        case .merge:
            if let c = req.conv, let t = req.target { res.convId = store.merge(c, into: t) } else { res.ok = false }
        case .open:
            if let id = req.contact, let c = store.contact(id) {
                let before = store.selectedId
                store.openChat(with: c, engine: req.text == "codex" ? .codex : .claude, model: req.model)
                res.convId = store.selectedId
                store.selectedId = before
            } else { res.ok = false }
        case .newProject:
            if let name = req.text, let c = try? store.createProject(named: name) {
                let before = store.selectedId
                store.openChat(with: c, engine: req.engine ?? .claude, model: req.model)
                res.convId = store.selectedId
                store.selectedId = before
            } else { res.ok = false; res.error = "Couldn't make that project." }
        case .setModel:
            if let c = req.conv { store.setModel(c, req.model) } else { res.ok = false }
        case .icon:
            if let id = req.contact, let c = store.contact(id), let path = store.iconPath(for: c) {
                res.png = Self.thumbnail(path)
            }
        }
        if !res.ok { res.error = "Missing details" }
        guard let out = try? Seal.close(res, key: key) else { return (500, Data()) }
        return (200, out)
    }

    private func snapshot(_ store: Store) -> RemoteSnapshot {
        let contacts = store.contacts.map { c in
            RemoteContact(id: c.id, name: c.name, displayName: store.displayName(c), parentId: c.parentId,
                          folder: URL(fileURLWithPath: c.projectPath).lastPathComponent, role: c.role,
                          colorIndex: c.colorIndex, hasIcon: store.iconPath(for: c) != nil, initials: c.initials)
        }
        return RemoteSnapshot(version: store.version, macName: Host.current().localizedName ?? "Mac",
                              contacts: contacts,
                              conversations: store.conversations.filter { !$0.hidden }.map(\.forRemote),
                              typing: store.typing,
                              busy: store.conversations.map(\.id).filter(store.isBusy),
                              models: ["claude": ModelCatalog.claude, "codex": ClaudeRunner.codexModels])
    }

    private static func thumbnail(_ path: String) -> Data? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        let side: CGFloat = 180
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // Basic brake on anyone guessing: 20 bad requests in a minute and that address is ignored for a while.
    private func noteFailure(_ peer: String) {
        let now = Date().timeIntervalSince1970
        failures[peer, default: []].append(now)
    }
    private func tooManyFailures(_ peer: String) -> Bool {
        let now = Date().timeIntervalSince1970
        let recent = (failures[peer] ?? []).filter { now - $0 < 60 }
        failures[peer] = recent
        return recent.count >= 20
    }
}
