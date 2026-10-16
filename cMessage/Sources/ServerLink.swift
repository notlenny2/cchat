import Foundation
import AppKit
import Security
import Network

/// A workstation Mac: it shows another Mac's chats (the server, where the agents actually run) and every button
/// asks that Mac to do it, exactly like the iPhone app. Same pairing link, same sealed requests, same relay away
/// from home. Nothing runs here and nothing of this Mac's own chats is touched (they wait in store.json for the day
/// this Mac is a server again).
@MainActor
final class ServerLink: ObservableObject {
    enum State: Equatable { case unlinked, connecting, online, offline(String) }

    @Published private(set) var pairing: PairingInfo?
    @Published private(set) var state: State = .unlinked
    @Published private(set) var viaRelay = false
    private(set) var snapshot: RemoteSnapshot?

    private weak var store: Store?
    private var loop: Task<Void, Never>?
    private var hostIndex = 0
    private var relayBase: String? { pairing?.relay ?? Relay.baseURL }
    private var iconRequested = Set<UUID>()
    private var mediaRequested = Set<String>()
    /// Agent messages already seen, so only new ones chime.
    private var heard: Set<UUID>?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Remote.longPollSeconds + 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Copies of the server's pictures, icons and documents, kept apart from this Mac's own chats.
    static let cacheDir: URL = {
        let d = Store.fileURL.deletingLastPathComponent().appendingPathComponent("server-cache", isDirectory: true)
        for sub in ["icons", "media"] {
            try? FileManager.default.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return d
    }()

    /// The one link (a workstation has exactly one server). Settings uses it to link and unlink.
    private(set) static weak var shared: ServerLink?

    init(store: Store) {
        self.store = store
        Self.shared = self
        // CCHAT_LINK: tests hand over a link without touching the Keychain.
        pairing = ProcessInfo.processInfo.environment["CCHAT_LINK"].flatMap(URL.init(string:)).flatMap(PairingInfo.init(url:))
            ?? LinkKeychain.load()
        state = pairing == nil ? .unlinked : .connecting
        start()
    }

    var serverName: String { snapshot?.macName ?? pairing?.macName ?? "your server Mac" }

    // MARK: Linking

    /// Takes the link a server Mac shows under Settings > This Mac (the same one its QR code holds).
    func link(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let p = PairingInfo(url: url) else { return false }
        LinkKeychain.save(p)
        pairing = p
        snapshot = nil; heard = nil
        iconRequested = []; mediaRequested = []
        hostIndex = 0
        state = .connecting
        stop(); start()
        Log.info("workstation: linked to \(p.macName)")
        return true
    }

    func unlink() {
        stop()
        LinkKeychain.delete()
        pairing = nil
        snapshot = nil
        state = .unlinked
        store?.mirror(nil, link: self)
    }

    // MARK: Sync

    func start() {
        guard pairing != nil, loop == nil else { return }
        loop = Task { [weak self] in
            await self?.pickRoute()
            var cycles = 0
            var misses = 0
            while !Task.isCancelled {
                guard let self else { return }
                cycles += 1
                if self.viaRelay && cycles % 8 == 0 { await self.pickRoute() }
                do {
                    let res = try await self.call(RPCRequest(op: .sync, since: self.snapshot?.version ?? -1))
                    if let s = res.snapshot { self.apply(s) }
                    self.state = .online
                    misses = 0
                } catch {
                    if Task.isCancelled || Self.cancelled(error) { return }
                    // One miss is usually a blip (the relay or Wi-Fi hiccupping): retry at once, quietly.
                    misses += 1
                    if misses >= 3 || error as? LinkError == .rejected {
                        self.state = .offline(Self.describe(error, relay: self.viaRelay, server: self.serverName))
                    }
                    await self.pickRoute()
                    try? await Task.sleep(nanoseconds: misses == 1 ? 500_000_000 : 3_000_000_000)
                }
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private func pickRoute() async {
        guard let p = pairing else { return }
        if let i = await Self.firstReachable(p.hosts, port: p.port) {
            hostIndex = i; viaRelay = false
        } else if relayBase != nil {
            viaRelay = true
        } else {
            hostIndex += 1; viaRelay = false
        }
    }

    private func apply(_ s: RemoteSnapshot) {
        snapshot = s
        fetchMissing(s)
        // An agent's answer that wasn't here last time: the same chime the server plays.
        let agentMsgs = Set(s.conversations.flatMap { c in c.messages.filter { $0.senderId != nil && $0.kind == .normal && !c.isCooler }.map(\.id) })
        if let heard, !agentMsgs.subtracting(heard).isEmpty { ReplyChime.play() }
        heard = agentMsgs
        store?.mirror(s, link: self)
        Log.info("workstation: synced \(s.conversations.count) chats, v\(s.version)")
        testOnce()
    }

    /// CCHAT_TEST_SEND="Chat title|text" (and CCHAT_TEST_FILE=/path): send it once from here after the first sync.
    private var tested = false
    private func testOnce() {
        guard !tested, let spec = ProcessInfo.processInfo.environment["CCHAT_TEST_SEND"], let store else { return }
        let parts = spec.components(separatedBy: "|")
        guard parts.count == 2, let conv = store.conversations.first(where: { store.title(for: $0) == parts[0] }) else { return }
        tested = true
        let files = ProcessInfo.processInfo.environment["CCHAT_TEST_FILE"].map { $0.components(separatedBy: ",") } ?? []
        store.send(parts[1], in: conv.id, attachments: files)
    }

    /// Where a server file lives here once it has been fetched (nil until then).
    func localMedia(_ name: String) -> String? {
        let u = Self.cacheDir.appendingPathComponent("media").appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        return FileManager.default.fileExists(atPath: u.path) ? u.path : nil
    }

    func localIcon(_ id: UUID) -> String? {
        let u = Self.cacheDir.appendingPathComponent("icons").appendingPathComponent("\(id.uuidString).png")
        return FileManager.default.fileExists(atPath: u.path) ? u.path : nil
    }

    private func fetchMissing(_ s: RemoteSnapshot) {
        for c in s.contacts where c.hasIcon && (c.parentId == nil || c.ownIcon == true) && !iconRequested.contains(c.id) {
            iconRequested.insert(c.id)
            Task {
                guard let png = try? await call(RPCRequest(op: .icon, contact: c.id)).png else { return }
                try? png.write(to: Self.cacheDir.appendingPathComponent("icons").appendingPathComponent("\(c.id.uuidString).png"))
                if let snap = snapshot { store?.mirror(snap, link: self) }
            }
        }
        // Only the newest few hundred messages per chat: older pictures come in when someone scrolls back to them anyway.
        let names = s.conversations.flatMap { $0.messages.suffix(200).flatMap { $0.attachments ?? [] } }
        for raw in names {
            let name = URL(fileURLWithPath: raw).lastPathComponent
            guard !name.isEmpty, localMedia(name) == nil, !mediaRequested.contains(name) else { continue }
            mediaRequested.insert(name)
            Task {
                guard let res = try? await call(RPCRequest(op: .media, text: name)), let d = res.media else { return }
                try? d.write(to: Self.cacheDir.appendingPathComponent("media").appendingPathComponent(name))
                if let snap = snapshot { store?.mirror(snap, link: self) }
            }
        }
    }

    // MARK: Asking the server

    func fire(_ req: RPCRequest) {
        Task {
            do {
                let res = try await deliver(req)
                if !res.ok { Log.error("workstation: \(req.op.rawValue) refused: \(res.error ?? "?")") }
            } catch { state = .offline(Self.describe(error, relay: viaRelay, server: serverName)) }
        }
    }

    /// Up to three tries with a fresh route in between. The repeat carries the same one-time code, so if the first
    /// try did get through the server refuses it (never runs it twice), and that refusal means it's done.
    private func deliver(_ req: RPCRequest) async throws -> RPCResponse {
        var tries = 0
        while true {
            do { return try await call(req) }
            catch LinkError.rejected where tries > 0 { return RPCResponse(nonce: req.nonce, ok: true) }
            catch {
                tries += 1
                if tries >= 3 || Self.cancelled(error) || error as? LinkError == .rejected { throw error }
                await pickRoute()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private static func cancelled(_ e: Error) -> Bool {
        e is CancellationError || (e as? URLError)?.code == .cancelled
    }

    func ask(_ req: RPCRequest) async -> RPCResponse? {
        do { return try await call(req) }
        catch { state = .offline(Self.describe(error, relay: viaRelay, server: serverName)); return nil }
    }

    /// Pictures go as JPEG and documents as they are, the way the phone sends its photos.
    func send(_ text: String, in conv: UUID, attachments: [String]) {
        var req = RPCRequest(op: .send, conv: conv, text: text)
        let pics = attachments.filter(Media.isPicture).prefix(RPCRequest.maxImages).compactMap { Self.jpeg($0) }
        let docs = attachments.filter(Documents.isDocument).prefix(RPCRequest.maxImages)
        if !pics.isEmpty { req.images = pics }
        if !docs.isEmpty {
            req.names = docs.map { Documents.displayName($0) }
            req.files = docs.compactMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        }
        fire(req)
    }

    static func jpeg(_ path: String, maxSide: CGFloat = 2048) -> Data? {
        guard let img = NSImage(contentsOfFile: path), let rep0 = img.representations.first else { return nil }
        let w = CGFloat(rep0.pixelsWide), h = CGFloat(rep0.pixelsHigh)
        let k = min(1, maxSide / max(w, h, 1))
        let size = NSSize(width: max(1, w * k), height: max(1, h * k))
        let out = NSImage(size: size)
        out.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    // MARK: Transport (the same as the phone's)

    private func call(_ req: RPCRequest) async throws -> RPCResponse {
        guard let p = pairing else { throw URLError(.userAuthenticationRequired) }
        let big = req.op == .media || req.images != nil || req.files != nil
        let timeout: TimeInterval = req.op == .sync ? Remote.longPollSeconds + 15 : (big ? 180 : 20)
        let url: URL
        if viaRelay, let base = relayBase {
            url = URL(string: "\(base)/v1/m/\(Relay.mailbox(p.key))/rpc?t=\(Int(timeout))")!
        } else {
            guard !p.hosts.isEmpty else { throw URLError(.userAuthenticationRequired) }
            url = URL(string: "http://\(p.hosts[hostIndex % p.hosts.count]):\(p.port)/rpc")!
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = try Seal.close(req, key: p.key)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = timeout + 5
        let (data, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw LinkError.rejected }
        guard status == 200 else { throw LinkError.http(status) }
        let res = try Seal.open(RPCResponse.self, from: data, key: p.key)
        guard res.nonce == req.nonce else { throw LinkError.mismatch }
        return res
    }

    enum LinkError: Error, Equatable { case rejected, http(Int), mismatch }

    private static func firstReachable(_ hosts: [String], port: UInt16) async -> Int? {
        await withTaskGroup(of: Int?.self) { group in
            for (i, h) in hosts.enumerated() { group.addTask { await reachable(h, port: port) ? i : nil } }
            var ok: [Int] = []
            for await r in group { if let r { ok.append(r) } }
            return ok.min()
        }
    }

    private static func reachable(_ host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let lock = NSLock()
            var finished = false
            func finish(_ v: Bool) {
                lock.lock(); defer { lock.unlock() }
                if !finished { finished = true; conn.cancel(); cont.resume(returning: v) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(false) }
        }
    }

    private static func describe(_ e: Error, relay: Bool, server: String) -> String {
        switch e {
        case LinkError.rejected: return "\(server) didn't recognize this Mac. Get a fresh link from it and link again."
        case LinkError.http(503) where relay: return "\(server) is offline or asleep. This will reconnect when it's back."
        case LinkError.http(504) where relay: return "\(server) didn't answer in time. Trying again."
        case LinkError.http(429) where relay: return "Slowing down for a moment, then trying again."
        case let u as URLError where u.code == .notConnectedToInternet: return "No internet connection right now."
        default: return "Can't reach \(server) right now. Trying again."
        }
    }
}

/// The link to the server Mac lives in this Mac's login Keychain, never synced, only readable here.
enum LinkKeychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "cchat") + ".server-link"

    static func save(_ p: PairingInfo) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "server", kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> PairingInfo? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "server",
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: d)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: "server"] as CFDictionary)
    }
}
