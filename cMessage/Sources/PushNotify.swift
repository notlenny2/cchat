import Foundation
import CoreGraphics

/// Buzzes the linked iPhone/iPad when an agent answers and the phone isn't open on cChat. The Mac asks the cChat
/// relay, which passes it on to Apple; only the Mac that owns the relay mailbox can ask. The relay sees the
/// notification text on its way through (that's what Apple needs to show it) and keeps nothing.
@MainActor
final class PushNotify {
    static let shared = PushNotify()

    struct Device: Codable, Equatable {
        var token: String
        var topic: String
        var name: String
        var added: Date
    }

    private(set) var devices: [Device] = []
    /// When each phone last talked to the Mac. A phone open on cChat syncs at least every 25 seconds.
    private var lastSeen: [String: Date] = [:]
    private static let url = Store.fileURL.deletingLastPathComponent().appendingPathComponent("push-devices.json")
    private static let tokenPattern = /^[0-9a-f]{64,200}$/
    private static let maxDevices = 10

    private init() {
        if let d = try? Data(contentsOf: Self.url), let list = try? JSONDecoder().decode([Device].self, from: d) {
            devices = list
        }
    }

    // MARK: Phones

    func register(token: String, topic: String, name: String) {
        guard (try? Self.tokenPattern.wholeMatch(in: token)) != nil, !topic.isEmpty, topic.count < 100 else { return }
        let clean = String(name.prefix(60))
        if let i = devices.firstIndex(where: { $0.token == token }) {
            guard devices[i].topic != topic || devices[i].name != clean else { return }
            devices[i].topic = topic; devices[i].name = clean
        } else {
            devices.append(Device(token: token, topic: topic, name: clean, added: Date()))
            if devices.count > Self.maxDevices { devices.removeFirst(devices.count - Self.maxDevices) }
            Log.info("push: \(clean) will get notifications")
        }
        save()
    }

    func remove(token: String) {
        guard devices.contains(where: { $0.token == token }) else { return }
        devices.removeAll { $0.token == token }
        save()
    }

    /// A new pairing code means new phones: forget the old ones.
    func removeAll() { devices = []; lastSeen = [:]; save() }

    func seen(_ token: String?) { if let token { lastSeen[token] = Date() } }
    func away(_ token: String?) { if let token { lastSeen[token] = nil } }

    private func save() {
        guard let d = try? JSONEncoder().encode(devices) else { return }
        try? d.write(to: Self.url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    // MARK: Sending

    /// An agent answered in a chat. `title` is who (or the group), `body` what they said.
    func agentReplied(chat: UUID, title: String, body: String, badge: Int, pairingKey: Data?, sitting: Bool) {
        guard Prefs.phoneNotify, let key = pairingKey, let base = Relay.baseURL, !devices.isEmpty else { return }
        // Someone typing at the Mac with this chat open is reading it there.
        if sitting { return }
        let now = Date()
        let targets = devices.filter { d in (lastSeen[d.token].map { now.timeIntervalSince($0) > 35 }) ?? true }
        guard !targets.isEmpty else { return }
        let text = Self.plain(body)
        guard let url = URL(string: "\(base)/v1/m/\(Relay.mailbox(key))/push") else { return }
        let token = Relay.macToken(key)
        for d in targets {
            let payload: [String: Any] = ["device": d.token, "topic": d.topic, "title": String(title.prefix(80)),
                                          "body": String(text.prefix(240)), "conv": chat.uuidString, "badge": badge]
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            r.timeoutInterval = 20
            Task { [weak self] in
                guard let (data, resp) = try? await URLSession.shared.data(for: r) else { Log.error("push: relay unreachable"); return }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if status == 200, answer?["ok"] as? Bool == true { return }
                let reason = answer?["reason"] as? String ?? "status \(status)"
                Log.error("push: \(d.name) not notified: \(reason)")
                // Apple says that phone is gone (app deleted, or a token from an old install): stop trying it.
                if ["Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason) {
                    self?.remove(token: d.token)
                }
            }
        }
    }

    /// Notification text, not markdown: drop emphasis marks and squash lines.
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return t.isEmpty ? "Sent you something." : t
    }

    /// Seconds since the last key press or click on this Mac.
    static var idleSeconds: Double {
        let any = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}
