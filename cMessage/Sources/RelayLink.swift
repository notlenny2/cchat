import Foundation

/// Keeps this Mac reachable from anywhere: one WebSocket out to the cChat relay per paired key (the phone's, plus
/// each paired agent's), so nothing on the Mac has to accept connections from the internet. Requests that come down
/// a socket go through exactly the same `RemoteServer.handle` as ones on the local network: still sealed, still
/// checked for staleness and replays, still limited to what the app's own buttons do.
@MainActor
final class RelayLink: ObservableObject {
    static let shared = RelayLink()

    /// Mailboxes with a live connection right now.
    @Published private(set) var online: Set<String> = []
    var handler: ((Data) async -> (Int, Data))?

    private var links: [String: Task<Void, Never>] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 90
        // Fail fast and retry on our own schedule; waiting for connectivity would sit on a refused connection.
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    var isOnline: Bool { !online.isEmpty }

    /// Connect a socket for each of these keys and drop any for keys that are gone.
    func update(keys: [Data]) {
        guard let base = Relay.baseURL else { stopAll(); return }
        var want: [String: Data] = [:]
        for k in keys { want[Relay.mailbox(k)] = k }
        for (m, t) in links where want[m] == nil { t.cancel(); links[m] = nil; online.remove(m) }
        for (m, k) in want where links[m] == nil {
            links[m] = Task { [weak self] in await self?.run(base: base, mailbox: m, token: Relay.macToken(k)) }
        }
    }

    func stopAll() {
        links.values.forEach { $0.cancel() }
        links = [:]
        online = []
    }

    /// Requests in flight per socket, and how big one may get, so a misbehaving relay can't eat the Mac's memory.
    private static let maxParts = 64
    private static let maxBody = RemoteServer.maxRequest + 1024 * 1024

    private func run(base: String, mailbox: String, token: String) async {
        var wait: UInt64 = 2
        let short = String(mailbox.prefix(6))
        while !Task.isCancelled {
            let ws = base.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
            guard let url = URL(string: "\(ws)/v1/m/\(mailbox)/mac") else { return }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: req)
            task.maximumMessageSize = 2 * 1024 * 1024
            task.resume()
            // The relay answers "ping" with "pong" without waking up; that's also how we know we're in.
            // No "pong" within 20 seconds of a ping means the socket is dead (or never opened): drop it and retry.
            var lastPong = Date()
            let pinger = Task { @MainActor in
                while !Task.isCancelled {
                    let sent = Date()
                    try? await task.send(.string("ping"))
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if lastPong < sent { task.cancel(with: .goingAway, reason: nil); return }
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
            var parts: [String: Data] = [:]
            do {
                while !Task.isCancelled {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let s):
                        if s == "pong" { lastPong = Date() }
                        if s == "pong", !online.contains(mailbox) {
                            online.insert(mailbox); wait = 2
                            Log.info("relay: connected (\(short))")
                        }
                    case .data(let d):
                        guard let (f, body) = Relay.parse(d) else { continue }
                        if parts[f.id] == nil && parts.count >= Self.maxParts { continue }
                        parts[f.id, default: Data()].append(body)
                        if parts[f.id]!.count > Self.maxBody { parts[f.id] = nil; continue }
                        guard f.last, let whole = parts.removeValue(forKey: f.id) else { continue }
                        let id = f.id
                        Task { [weak self] in
                            guard let handler = self?.handler else { return }
                            let (status, out) = await handler(whole)
                            for frame in Relay.frames(id: id, status: status, body: out) {
                                do { try await task.send(.data(frame)) } catch { break }
                            }
                        }
                    @unknown default: break
                    }
                }
            } catch {
                if online.contains(mailbox) { Log.info("relay: disconnected (\(short)): \(error.localizedDescription)") }
            }
            pinger.cancel()
            task.cancel(with: .goingAway, reason: nil)
            online.remove(mailbox)
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            wait = min(30, wait * 2)
        }
    }
}
