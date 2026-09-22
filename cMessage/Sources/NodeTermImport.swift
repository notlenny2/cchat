import Foundation

/// Reads NodeTerm's canvas (read-only) and turns each Claude chat on it into a cMessage contact
/// with its memory attached. NodeTerm keeps projects in two places: `<folder>/.nodeterm/project.json`
/// for folder-backed projects, and `inline-projects/*.json` in its app-support dir for the rest.
/// Session ids live on the node (`agentSessionId`) or, for older nodes, in `agent-status.json`.
enum NodeTermImport {
    struct Chat {
        var nodeId: String
        var projectName: String
        var title: String
        var sessionId: String
        var cwd: String
        var lastReply: String?
        var lastDate: Date?
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let appDir = home.appendingPathComponent("Library/Application Support/node-terminal")

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: appDir.path) }

    static func scan() -> [Chat] {
        let fm = FileManager.default
        var status: [String: String] = [:]
        if let d = try? Data(contentsOf: appDir.appendingPathComponent("agent-status.json")),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let nodes = o["nodes"] as? [String: [String: Any]] {
            for (id, n) in nodes { if let s = n["sessionId"] as? String { status[id] = s } }
        }

        var files: [URL] = []
        let projects = Prefs.projectsRoot
        for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let f = dir.appendingPathComponent(".nodeterm/project.json")
            if fm.fileExists(atPath: f.path) { files.append(f) }
        }
        let inline = appDir.appendingPathComponent("inline-projects")
        files += ((try? fm.contentsOfDirectory(at: inline, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }

        var chats: [Chat] = []
        var seenSessions = Set<String>()
        for f in files {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                Log.error("nodeterm: couldn't read \(f.path)")
                continue
            }
            let projectName = (o["name"] as? String) ?? "NodeTerm"
            for n in (o["nodes"] as? [[String: Any]]) ?? [] {
                guard n["kind"] as? String == "terminal", n["agentId"] as? String == "claude",
                      let id = n["id"] as? String,
                      let sid = (n["agentSessionId"] as? String) ?? status[id],
                      !seenSessions.contains(sid),
                      let file = sessionFile(sid),
                      let cwd = sessionCwd(file) else { continue }
                seenSessions.insert(sid)
                let title = (n["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Chat"
                let last = lastAssistant(file)
                chats.append(Chat(nodeId: id, projectName: projectName, title: title, sessionId: sid,
                                  cwd: cwd, lastReply: last?.text, lastDate: last?.date ?? modified(file)))
            }
        }
        Log.info("nodeterm scan: \(chats.count) chats with memory")
        return chats
    }

    /// Claude stores each session under ~/.claude/projects/<encoded folder>/<id>.jsonl.
    private static func sessionFile(_ sid: String) -> URL? {
        let root = home.appendingPathComponent(".claude/projects")
        for dir in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let f = dir.appendingPathComponent("\(sid).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    /// The folder the session was started in. A resume only finds the session from that folder.
    private static func sessionCwd(_ file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let head = h.readData(ofLength: 512 * 1024)
        for line in head.split(separator: UInt8(ascii: "\n")) {
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let c = o["cwd"] as? String { return c }
        }
        return nil
    }

    private static func modified(_ file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The agent's last plain-text message and when it was sent, so the imported chat opens where it left off.
    private static func lastAssistant(_ file: URL) -> (text: String, date: Date?)? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 4 * 1024 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        let tail = h.readDataToEndOfFile()
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  o["type"] as? String == "assistant",
                  let msg = o["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return (text, (o["timestamp"] as? String).flatMap { f.date(from: $0) })
            }
        }
        return nil
    }
}

extension Store {
    /// Adds every NodeTerm chat not already here. NodeTerm projects become contacts, each chat a
    /// sub-contact under it. Returns how many were added.
    @discardableResult
    func importNodeTerm() -> Int {
        let chats = NodeTermImport.scan()
        let already = Set(contacts.compactMap(\.nodeTermId))
        var added = 0
        for chat in chats where !already.contains(chat.nodeId) {
            let project = nodeTermProject(named: chat.projectName, cwd: chat.cwd)
            var c = Contact(name: chat.title, projectPath: chat.cwd, parentId: project.id,
                            colorIndex: contacts.count)
            c.nodeTermId = chat.nodeId
            contacts.append(c)

            var conv = Conversation(participantIds: [c.id])
            conv.sessions[c.id.uuidString] = chat.sessionId
            conv.forkNext = [c.id.uuidString]
            let when = chat.lastDate ?? Date()
            conv.messages.append(Message(senderId: nil, text: "Picked up from NodeTerm. Memory carried over; the terminal keeps its own copy.", date: when, kind: .system))
            if let last = chat.lastReply {
                var (body, _) = Store.parse(last)
                if body.count > 700 { body = String(body.prefix(700)) + "…" }
                conv.messages.append(Message(senderId: c.id, text: body, date: when))
            }
            // Everything so far is history the agent already has, so don't resend it.
            conv.seenCount[c.id.uuidString] = conv.messages.count
            conversations.append(conv)
            added += 1
        }
        save()
        findMissingIcons()
        return added
    }

    private func nodeTermProject(named name: String, cwd: String) -> Contact {
        if let p = contacts.first(where: { !$0.isSubContact && $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return p }
        let c = Contact(name: name, projectPath: cwd, colorIndex: contacts.count)
        contacts.append(c)
        return c
    }
}
