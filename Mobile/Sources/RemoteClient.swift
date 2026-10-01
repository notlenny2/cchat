import Foundation
import SwiftUI
import Security
import Network

/// Keeps the phone in step with the Mac. One long-poll loop asks "anything new since version N?"
/// and the Mac answers as soon as something changes (or after 25 seconds). Actions are single
/// sealed requests. Nothing runs on the phone; it only asks the Mac to do what its buttons do.
@MainActor
final class RemoteClient: ObservableObject {
    enum Link: Equatable { case unpaired, connecting, online, offline(String) }

    @Published private(set) var pairing: PairingInfo?
    @Published private(set) var link: Link = .unpaired
    @Published private(set) var snapshot: RemoteSnapshot?
    @Published private(set) var icons: [UUID: UIImage] = [:]
    /// A notification was tapped: the chat list opens this chat.
    @Published var openRequest: UUID?
    /// This phone's notification address from Apple (hex). Sent along with every request so the Mac knows
    /// the app is open here and doesn't buzz it.
    private var pushToken: String? = UserDefaults.standard.string(forKey: "pushToken")

    private var loop: Task<Void, Never>?
    private var hostIndex = 0
    /// Away from home: going through the relay because no home address answered.
    @Published private(set) var viaRelay = false
    private var relayBase: String? { pairing?.relay ?? Relay.baseURL }
    private var iconRequested = Set<UUID>()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Remote.longPollSeconds + 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init() {
        pairing = Keychain.load()
        link = pairing == nil ? .unpaired : .connecting
    }

    // MARK: Pairing

    func pair(with url: URL) -> Bool {
        guard let p = PairingInfo(url: url) else { return false }
        Keychain.save(p)
        pairing = p
        snapshot = nil
        icons = [:]; iconRequested = []
        hostIndex = 0
        link = .connecting
        // A loop already running is still using the old addresses; start over with the new ones.
        stop()
        start()
        return true
    }

    func unpair() {
        stop()
        Keychain.delete()
        pairing = nil
        snapshot = nil
        link = .unpaired
    }

    // MARK: Sync loop

    func start() {
        guard pairing != nil, loop == nil else { return }
        loop = Task { [weak self] in
            // Start on an address that actually answers, not whichever was listed first; else the relay.
            await self?.pickRoute()
            var cycles = 0
            while !Task.isCancelled {
                guard let self else { return }
                // On the relay, look for home every few minutes: the direct way is quicker when it's there.
                cycles += 1
                if self.viaRelay && cycles % 8 == 0 { await self.pickRoute() }
                do {
                    let res = try await self.call(RPCRequest(op: .sync, since: self.snapshot?.version ?? -1))
                    if let s = res.snapshot {
                        self.snapshot = s
                        self.fetchMissingIcons(s)
                    }
                    self.link = .online
                } catch is CancellationError {
                    return
                } catch {
                    var why = Self.describe(error, relay: self.viaRelay)
                    if !self.viaRelay, self.relayBase == nil, let p = self.pairing, !p.hosts.isEmpty,
                       await Self.localNetworkDenied(host: p.hosts[self.hostIndex % p.hosts.count], port: p.port) {
                        why = "iPhone is blocking cChat from your home network. Turn on Settings > Privacy & Security > Local Network > cChat."
                    }
                    self.link = .offline(why)
                    // Try every address the Mac gave at once and keep whichever answers, instead of waiting out a
                    // dead one (a Mac on Wi-Fi AND a cable can be reachable on only one of them). None: the relay.
                    await self.pickRoute()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Notifications

    /// Apple handed us this phone's notification address: tell the Mac so it can buzz us when an agent answers.
    func registerPush(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        pushToken = hex
        UserDefaults.standard.set(hex, forKey: "pushToken")
        var r = RPCRequest(op: .notify, text: UIDevice.current.name)
        r.topic = Bundle.main.bundleIdentifier
        Task { _ = try? await call(r) }
    }

    /// Going to the background: let the Mac know straight away so the next answer buzzes this phone.
    func wentAway() {
        guard pairing != nil, pushToken != nil else { return }
        let app = UIApplication.shared
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = app.beginBackgroundTask { app.endBackgroundTask(bg) }
        Task {
            _ = try? await call(RPCRequest(op: .away))
            app.endBackgroundTask(bg)
        }
    }

    /// Home address if one answers, otherwise the relay (when there is one), otherwise keep cycling home addresses.
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

    // MARK: Actions

    func send(_ text: String, in conv: UUID) { fire(RPCRequest(op: .send, conv: conv, text: text)) }

    /// Sends pictures (and an optional note). Waits for the Mac so the composer can keep them if it fails.
    func send(_ text: String, pictures: [UIImage], in conv: UUID) async -> Bool {
        let jpegs = pictures.prefix(RPCRequest.maxImages).compactMap { Self.jpeg($0) }
        guard !jpegs.isEmpty else { return false }
        var req = RPCRequest(op: .send, conv: conv, text: text)
        req.images = jpegs
        do { return try await call(req).ok }
        catch { link = .offline(Self.describe(error)); return false }
    }

    /// Longest side 2048px, JPEG: a 12MP photo goes from ~5 MB to a few hundred KB, still plenty for an agent to read.
    static func jpeg(_ img: UIImage, maxSide: CGFloat = 2048) -> Data? {
        let s = img.size
        let scale = min(1, maxSide / max(s.width, s.height, 1))
        let size = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return out.jpegData(compressionQuality: 0.8)
    }
    func rename(_ conv: UUID, to name: String) { fire(RPCRequest(op: .rename, conv: conv, text: name)) }
    func togglePin(_ conv: UUID) { fire(RPCRequest(op: .pin, conv: conv)) }
    /// Mark as Read (also clears Needs you) or Mark as Unread.
    func setRead(_ conv: UUID, read: Bool) { fire(RPCRequest(op: .read, conv: conv, wait: read)) }
    func stopReply(_ conv: UUID) { fire(RPCRequest(op: .stop, conv: conv)) }
    func markRead(_ conv: UUID) { fire(RPCRequest(op: .markRead, conv: conv)) }
    func hide(_ conv: UUID) { fire(RPCRequest(op: .hide, conv: conv)) }
    func file(_ conv: UUID, into folder: String) { fire(RPCRequest(op: .file, conv: conv, text: folder)) }

    /// A contact's top-level project, for the chat list's folders (same rule as the Mac's `Store.projectOf`).
    func projectOf(_ id: UUID) -> (id: UUID, name: String)? {
        guard var c = contact(id) else { return nil }
        if let p = c.parentId, let parent = contact(p) { c = parent }
        return c.noProject == true ? nil : (c.id, c.name)
    }
    func folders(_ convs: [Conversation]) -> [ChatFolders.Folder] { ChatFolders.sort(convs, project: projectOf) }
    var projects: [RemoteContact] {
        (snapshot?.contacts ?? []).filter { $0.parentId == nil && $0.noProject != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func merge(_ source: UUID, into target: UUID) async -> UUID? {
        try? await call(RPCRequest(op: .merge, conv: source, target: target)).convId
    }

    func openChat(with contact: UUID, engine: Engine = .claude, model: String = "", fresh: Bool = false) async -> UUID? {
        var r = RPCRequest(op: .open, contact: contact, text: engine.rawValue, model: model)
        if fresh { r.fresh = true }
        return try? await call(r).convId
    }

    func newProject(_ name: String, engine: Engine, model: String) async -> UUID? {
        try? await call(RPCRequest(op: .newProject, text: name, model: model, engine: engine)).convId
    }

    /// Pictures and videos from chats, fetched once and kept for this session.
    private var mediaCache: [String: URL] = [:]
    func media(_ name: String) async -> URL? {
        if let u = mediaCache[name] { return u }
        guard let res = try? await call(RPCRequest(op: .media, text: name)), let d = res.media else { return nil }
        let ext = res.isVideo == true ? (URL(fileURLWithPath: name).pathExtension.isEmpty ? "mp4" : URL(fileURLWithPath: name).pathExtension) : "jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent).\(ext)")
        guard (try? d.write(to: url)) != nil else { return nil }
        mediaCache[name] = url
        return url
    }

    func callInTeam(_ project: UUID, members: [String], asGroup: Bool, opener: String, engine: Engine, model: String) async -> UUID? {
        try? await call(RPCRequest(op: .team, contact: project, text: opener, model: model, engine: engine, wait: asGroup, names: members)).convId
    }

    func removeFromGroup(_ conv: UUID, _ contact: UUID) { fire(RPCRequest(op: .leave, conv: conv, contact: contact)) }
    func setChatter(_ conv: UUID, on: Bool) { fire(RPCRequest(op: .chatter, conv: conv, wait: on)) }

    func setModel(_ conv: UUID, _ model: String) { fire(RPCRequest(op: .setModel, conv: conv, model: model)) }

    func models(for engine: Engine) -> [ModelOption] {
        snapshot?.models?[engine.rawValue] ?? (engine == .claude ? ModelCatalog.claude : [ModelOption(id: "", label: "Default", note: "")])
    }

    /// Engines the Mac says it can run (Claude always; Codex and Gemini when installed there). An older Mac
    /// that sends no list still gets Claude and Codex, as before.
    var availableEngines: [Engine] {
        guard let m = snapshot?.models else { return [.claude, .codex] }
        return Engine.allCases.filter { $0 == .claude || m[$0.rawValue] != nil }
    }

    func modelSummary(_ c: Conversation) -> String {
        let e = c.engine ?? .claude
        return e.label + (ModelCatalog.label(c.model, in: models(for: e)).map { " · \($0)" } ?? "")
    }

    private func fire(_ req: RPCRequest) {
        Task {
            do { _ = try await call(req) }
            catch { link = .offline(Self.describe(error)) }
        }
    }

    private func fetchMissingIcons(_ s: RemoteSnapshot) {
        for c in s.contacts where c.hasIcon && !iconRequested.contains(c.id) {
            iconRequested.insert(c.id)
            Task {
                if let png = try? await call(RPCRequest(op: .icon, contact: c.id)).png, let img = UIImage(data: png) {
                    icons[c.id] = img
                }
            }
        }
    }

    // MARK: Transport

    private func call(_ req: RPCRequest) async throws -> RPCResponse {
        guard let p = pairing else { throw URLError(.userAuthenticationRequired) }
        var req = req
        req.device = pushToken
        let timeout: TimeInterval = req.op == .sync ? Remote.longPollSeconds + 15 : (req.op == .media || req.images != nil ? 180 : 15)
        let url: URL
        if viaRelay, let base = relayBase {
            // The relay holds the request open for as long as we say, so it matches our own timeout.
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
        if status == 401 { throw ClientError.rejected }
        guard status == 200 else { throw ClientError.http(status) }
        let res = try Seal.open(RPCResponse.self, from: data, key: p.key)
        guard res.nonce == req.nonce else { throw ClientError.mismatch }
        return res
    }

    enum ClientError: Error { case rejected, http(Int), mismatch }

    /// The earliest-listed host that accepts a connection, all tried at the same time (a few seconds at most).
    /// The Mac lists its best address first, so list order wins over whichever answered quickest.
    private static func firstReachable(_ hosts: [String], port: UInt16) async -> Int? {
        await withTaskGroup(of: Int?.self) { group in
            for (i, h) in hosts.enumerated() {
                group.addTask { await reachable(h, port: port) ? i : nil }
            }
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

    /// Asks the network stack directly whether iOS is refusing local-network access for this app,
    /// which otherwise just looks like "can't connect".
    private static func localNetworkDenied(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            var finished = false
            func finish(_ v: Bool) { if !finished { finished = true; conn.cancel(); cont.resume(returning: v) } }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(false)
                case .waiting, .failed: finish(conn.currentPath?.unsatisfiedReason == .localNetworkDenied)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(conn.currentPath?.unsatisfiedReason == .localNetworkDenied) }
        }
    }

    private static func describe(_ e: Error, relay: Bool = false) -> String {
        switch e {
        case ClientError.rejected: return "Your Mac didn't recognize this device. Scan the code again."
        case ClientError.http(503) where relay: return "Your Mac is offline or asleep. Wake it up and this will reconnect."
        case ClientError.http(504) where relay: return "Your Mac didn't answer in time. Trying again."
        case ClientError.http(429) where relay: return "Slowing down for a moment, then trying again."
        case ClientError.mismatch: return "Got a garbled answer from the Mac."
        case let u as URLError where u.code == .timedOut: return "Can't reach your Mac right now."
        case let u as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(u.code):
            return relay ? "No internet connection right now." : "Can't reach your Mac. Is it awake and on the same Wi-Fi?"
        default: return "Can't reach your Mac right now."
        }
    }

    // MARK: Lookup

    func contact(_ id: UUID?) -> RemoteContact? { snapshot?.contacts.first { $0.id == id } }
    func conversation(_ id: UUID?) -> Conversation? { snapshot?.conversations.first { $0.id == id } }

    var conversations: [Conversation] {
        (snapshot?.conversations ?? []).sorted { $0.lastDate > $1.lastDate }
    }

    func title(_ c: Conversation) -> String {
        if let t = c.title, !t.isEmpty { return t }
        let names = c.participantIds.compactMap { contact($0)?.displayName }
        return names.isEmpty ? "Nobody" : names.joined(separator: ", ")
    }

    func typing(in conv: UUID) -> UUID? { snapshot?.typing[conv] }
    func waitingFor(_ conv: UUID) -> String? { snapshot?.waitingFor?[conv] }
    func isBusy(_ conv: UUID) -> Bool { snapshot?.busy.contains(conv) ?? false }
}

/// The pairing key lives in the iOS Keychain, only readable while the device is unlocked, never synced.
enum Keychain {
    /// "<mac app id>.pairing" (the phone's id minus ".mobile"), so it matches what earlier builds saved.
    private static let service = (Bundle.main.bundleIdentifier ?? "cchat").replacingOccurrences(of: ".mobile", with: "") + ".pairing"

    static func save(_ p: PairingInfo) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> PairingInfo? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: d)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
