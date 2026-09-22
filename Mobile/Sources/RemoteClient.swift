import Foundation
import SwiftUI
import Security

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

    private var loop: Task<Void, Never>?
    private var hostIndex = 0
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
            while !Task.isCancelled {
                guard let self else { return }
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
                    self.link = .offline(Self.describe(error))
                    self.hostIndex += 1
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Actions

    func send(_ text: String, in conv: UUID) { fire(RPCRequest(op: .send, conv: conv, text: text)) }
    func rename(_ conv: UUID, to name: String) { fire(RPCRequest(op: .rename, conv: conv, text: name)) }
    func togglePin(_ conv: UUID) { fire(RPCRequest(op: .pin, conv: conv)) }
    func stopReply(_ conv: UUID) { fire(RPCRequest(op: .stop, conv: conv)) }
    func markRead(_ conv: UUID) { fire(RPCRequest(op: .markRead, conv: conv)) }
    func hide(_ conv: UUID) { fire(RPCRequest(op: .hide, conv: conv)) }

    func merge(_ source: UUID, into target: UUID) async -> UUID? {
        try? await call(RPCRequest(op: .merge, conv: source, target: target)).convId
    }

    func openChat(with contact: UUID) async -> UUID? {
        try? await call(RPCRequest(op: .open, contact: contact)).convId
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
        guard let p = pairing, !p.hosts.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let host = p.hosts[hostIndex % p.hosts.count]
        var r = URLRequest(url: URL(string: "http://\(host):\(p.port)/rpc")!)
        r.httpMethod = "POST"
        r.httpBody = try Seal.close(req, key: p.key)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if req.op != .sync { r.timeoutInterval = 15 }
        let (data, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw ClientError.rejected }
        guard status == 200 else { throw ClientError.http(status) }
        let res = try Seal.open(RPCResponse.self, from: data, key: p.key)
        guard res.nonce == req.nonce else { throw ClientError.mismatch }
        return res
    }

    enum ClientError: Error { case rejected, http(Int), mismatch }

    private static func describe(_ e: Error) -> String {
        switch e {
        case ClientError.rejected: return "Your Mac didn't recognize this device. Scan the code again."
        case ClientError.mismatch: return "Got a garbled answer from the Mac."
        case let u as URLError where u.code == .timedOut: return "Can't reach your Mac right now."
        case let u as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(u.code):
            return "Can't reach your Mac. Is it awake and on the same Wi-Fi?"
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
    func isBusy(_ conv: UUID) -> Bool { snapshot?.busy.contains(conv) ?? false }
}

/// The pairing key lives in the iOS Keychain, only readable while the device is unlocked, never synced.
enum Keychain {
    private static let service = "com.example.cmessage.pairing"

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
