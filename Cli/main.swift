import Foundation

// cchat: lets another agent (Helper, a script, a Claude session) text the agents in cChat.
//
//   cchat pair <Name>                 run on the cChat Mac: makes a key for <Name> and a config file
//   cchat list                        chats and contacts you can text
//   cchat send <chat> <message...>    send and return right away
//   cchat ask  <chat> <message...>    send and wait for the agents' replies (up to 15 minutes)
//
// <chat> is what the user would call it: a chat title ("Garden", "example Tools") or a contact ("Website UX").
// Add --json for machine-readable output. Config: $CCHAT_CONFIG or ~/.config/cchat/client.json.
// Messages show up in cChat labeled with the client's name, never as the user.

struct ClientConfig: Codable {
    var name: String
    var key: Data
    var hosts: [String]
    var port: UInt16
}

func fail(_ s: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
args.removeAll { $0 == "--json" }
guard let cmd = args.first else {
    fail("usage: cchat pair <Name> | list | send <chat> <message> | ask <chat> <message>  [--json]", 2)
}
args.removeFirst()

let home = FileManager.default.homeDirectoryForCurrentUser
let configURL = ProcessInfo.processInfo.environment["CCHAT_CONFIG"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent(".config/cchat/client.json")

func out(_ value: Any) {
    let d = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: d, as: UTF8.self))
}

if cmd == "pair" {
    guard let name = args.first, name.range(of: #"^[A-Za-z][A-Za-z0-9 _-]{0,31}$"#, options: .regularExpression) != nil else {
        fail("give the client a name, letters/numbers, e.g. cchat pair Helper", 2)
    }
    let base = ProcessInfo.processInfo.environment["CMESSAGE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent("Library/Application Support/\(Flavor.dataFolder)")
    let support = base.appendingPathComponent("clients", isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let keyFile = support.appendingPathComponent("\(name).key")
    let key = Seal.newKey()
    do {
        try key.write(to: keyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        let cfg = ClientConfig(name: name, key: key, hosts: ["127.0.0.1"] + args.dropFirst(), port: Remote.port)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cfg).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    } catch { fail("couldn't save the key: \(error)") }
    print("Paired \(name). Config: \(configURL.path)")
    print("To use it from another Mac, copy that file there and add this Mac's address to \"hosts\".")
    print("To revoke, delete \(keyFile.path)")
    exit(0)
}

guard let data = try? Data(contentsOf: configURL), let cfg = try? JSONDecoder().decode(ClientConfig.self, from: data) else {
    fail("no config at \(configURL.path). On the cChat Mac run: cchat pair <Name>")
}

func call(_ req: RPCRequest, timeout: TimeInterval) async throws -> RPCResponse {
    var last: Error = URLError(.cannotConnectToHost)
    for host in cfg.hosts {
        var r = URLRequest(url: URL(string: "http://\(host):\(cfg.port)/rpc")!)
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.httpBody = try Seal.close(req, key: cfg.key)
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { fail("cChat didn't accept this key (revoked, or the clock is off).") }
            guard status == 200 else { throw URLError(.badServerResponse) }
            let res = try Seal.open(RPCResponse.self, from: d, key: cfg.key)
            guard res.nonce == req.nonce else { fail("garbled answer from cChat") }
            return res
        } catch { last = error }
    }
    throw last
}

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        switch cmd {
        case "list":
            let s = try await call(RPCRequest(op: .sync, since: -1), timeout: 30).snapshot
            let chats = (s?.conversations ?? []).map { c -> String in
                if let t = c.title, !t.isEmpty { return t }
                return c.participantIds.compactMap { id in s?.contacts.first { $0.id == id }?.displayName }.joined(separator: ", ")
            }
            let contacts = (s?.contacts ?? []).map(\.displayName)
            if json { out(["chats": chats, "contacts": contacts]) }
            else { print("Chats:\n  " + chats.joined(separator: "\n  ") + "\nContacts:\n  " + contacts.joined(separator: "\n  ")) }
        case "send", "ask":
            guard args.count >= 2 else { fail("usage: cchat \(cmd) <chat> <message>", 2) }
            let to = args[0], text = args.dropFirst().joined(separator: " ")
            let wait = cmd == "ask"
            let res = try await call(RPCRequest(op: .ask, text: text, to: to, wait: wait), timeout: wait ? 16 * 60 : 30)
            if !res.ok { fail(res.error ?? "cChat said no.") }
            if json { out(["ok": true, "replies": res.replies ?? [], "note": res.error ?? ""]) }
            else if wait { print((res.replies ?? []).joined(separator: "\n\n")); if let e = res.error { print("(\(e))") } }
            else { print("Sent to \(to).") }
        default:
            fail("unknown command \(cmd)", 2)
        }
    } catch {
        fail("couldn't reach cChat: \(error.localizedDescription)")
    }
    sema.signal()
}
sema.wait()
