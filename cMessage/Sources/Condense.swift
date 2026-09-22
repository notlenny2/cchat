import Foundation

/// Keeps agents' memory from growing forever. A chat's memory is a Claude Code session, and every step an
/// agent takes re-reads all of it; on 2026-09-22 a few chats carrying 600k-900k tokens each used over 80% of
/// the user's Claude allowance. After a turn, if the session has grown past a sensible size, cChat asks Claude Code to
/// condense it (its own `/compact`): same session, same memory of what matters, a fraction of the size.
/// Works per agent per chat, so every member of a group chat is condensed on its own.
enum Condense {
    /// What to keep when condensing. `/compact` takes these as its instructions.
    static let command = """
    /compact Keep what the user asked for and why, decisions made, where the work stands, open to-dos and \
    promises, names of files and features involved, and anything the user said to remember. Drop tool \
    output, file dumps, logs and step-by-step detail that's already done.
    """

    /// Condense once a session passes this. 250k on the 1M-token models, 60% of the window on smaller ones
    /// (Claude Code only tidies up by itself when a session is nearly full, which is far too late for cost).
    static func limit(window: Int?) -> Int {
        // Tests set CCHAT_CONDENSE_AT to make it happen on a small chat.
        if let t = ProcessInfo.processInfo.environment["CCHAT_CONDENSE_AT"].flatMap(Int.init) { return t }
        let w = window ?? 200_000
        return min(250_000, Int(Double(w) * 0.6))
    }

    /// How much the session holds right now: the prompt size of its most recent model call, read from the tail
    /// of Claude Code's own record of the session. nil if it can't be found.
    static func size(session: String) -> Int? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        guard let file = dirs.lazy.map({ $0.appendingPathComponent("\(session).jsonl") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 1_000_000 ? end - 1_000_000 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"usage\""),
                  let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (o["isSidechain"] as? Bool) != true,
                  let m = o["message"] as? [String: Any], (m["model"] as? String) != "<synthetic>",
                  let u = m["usage"] as? [String: Any] else { continue }
            let n = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
            if n > 0 { return n }
        }
        return nil
    }
}
