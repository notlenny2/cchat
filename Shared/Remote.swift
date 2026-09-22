import Foundation
import CryptoKit

/// The link between the Mac (where agents actually run) and the iPhone/iPad (remote screens).
///
/// Transport is plain HTTP on the local network, but every request and response body is sealed
/// with ChaCha20-Poly1305 using a 256-bit key that only exists on the paired devices (it travels
/// once, in the pairing QR code). Anything that fails to open is rejected, so nobody else on the
/// network can read the chats or send as the user. Requests carry a timestamp and a one-time nonce, and
/// the Mac refuses anything stale or seen before, so a captured request can't be replayed.
enum Remote {
    static let port: UInt16 = 47800
    static let bonjourType = "_cmessage._tcp"
    static let maxClockSkew: TimeInterval = 120
    static let longPollSeconds: TimeInterval = 25
}

struct PairingInfo: Codable, Equatable {
    var key: Data
    var hosts: [String]
    var port: UInt16
    var macName: String

    /// `cmessage://pair?k=...&h=host1,host2&p=47800&n=Mac`
    var url: URL {
        var c = URLComponents()
        c.scheme = "cmessage"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "k", value: key.base64URL),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "n", value: macName),
        ]
        return c.url!
    }

    init(key: Data, hosts: [String], port: UInt16, macName: String) {
        self.key = key; self.hosts = hosts; self.port = port; self.macName = macName
    }

    init?(url: URL) {
        guard url.scheme == "cmessage", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let k = v("k").flatMap(Data.init(base64URL:)), k.count == 32,
              let h = v("h"), let p = v("p").flatMap(UInt16.init) else { return nil }
        self.init(key: k, hosts: h.split(separator: ",").map(String.init).filter { !$0.isEmpty },
                  port: p, macName: v("n") ?? "Mac")
    }
}

/// A contact as the phone sees it: no folder paths or file locations leave the Mac.
struct RemoteContact: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var displayName: String
    var parentId: UUID?
    var folder: String
    var role: String
    var colorIndex: Int
    var hasIcon: Bool
    var initials: String
}

struct RemoteSnapshot: Codable {
    var version: Int
    var macName: String
    var contacts: [RemoteContact]
    /// Memory ids and bookkeeping are stripped before sending.
    var conversations: [Conversation]
    /// conversation id -> who is typing (a contact id, or `routerId` while the group decides).
    var typing: [UUID: UUID]
    var busy: [UUID]
    /// Models the phone can offer, per engine.
    var models: [String: [ModelOption]]? = nil
}

struct RPCRequest: Codable {
    enum Op: String, Codable { case sync, send, rename, pin, stop, merge, markRead, open, icon, hide, setModel }
    var op: Op
    var ts: TimeInterval = Date().timeIntervalSince1970
    var nonce: String = UUID().uuidString
    var conv: UUID? = nil
    var target: UUID? = nil
    var contact: UUID? = nil
    var text: String? = nil
    var since: Int? = nil
    var model: String? = nil
}

struct RPCResponse: Codable {
    var nonce: String
    var ok: Bool
    var error: String? = nil
    var snapshot: RemoteSnapshot? = nil
    var convId: UUID? = nil
    var png: Data? = nil
}

enum Seal {
    static func close<T: Encodable>(_ value: T, key: Data) throws -> Data {
        let plain = try JSONEncoder().encode(value)
        return try ChaChaPoly.seal(plain, using: SymmetricKey(data: key)).combined
    }

    static func open<T: Decodable>(_ type: T.Type, from data: Data, key: Data) throws -> T {
        let box = try ChaChaPoly.SealedBox(combined: data)
        let plain = try ChaChaPoly.open(box, using: SymmetricKey(data: key))
        return try JSONDecoder().decode(T.self, from: plain)
    }

    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

extension Conversation {
    /// What leaves the Mac: the chat itself, minus memory ids and internal bookkeeping.
    var forRemote: Conversation {
        var c = self
        c.sessions = [:]
        c.seenCount = [:]
        c.forkNext = nil
        c.pending = []
        c.routeNext = nil
        c.photoPath = nil
        c.messages = c.messages.map { m in
            var m = m
            if let a = m.attachments, !a.isEmpty {
                m.text = ([String](repeating: "📷", count: a.count).joined() + " " + m.text).trimmingCharacters(in: .whitespaces)
                m.attachments = nil
            }
            return m
        }
        return c
    }
}

/// Stand-in "typing" id while a group is deciding who should answer.
let routerTypingId = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
