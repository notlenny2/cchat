import Foundation

/// Reads how much of the user's Claude and Codex plans is used up. Nothing here signs in or touches
/// credentials: Claude Code prints the numbers itself on every turn (`rate_limit_event` in its stream
/// output), and Codex writes them into its own session logs in ~/.codex/sessions.
enum UsageWatch {
    /// From a Claude Code `rate_limit_event` line.
    static func claude(_ event: [String: Any]) -> PlanUsage? {
        guard let info = event["rate_limit_info"] as? [String: Any],
              let windows = info["unifiedWindows"] as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = windows[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(used: u, resetsAt: (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        let usage = PlanUsage(session: window("five_hour"), week: window("seven_day"), asOf: Date())
        return usage.session == nil && usage.week == nil ? nil : usage
    }

    /// The newest numbers Codex logged, from any Codex session on this Mac (in cChat or not).
    static func codex() -> PlanUsage? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        for file in newestFiles(in: root, limit: 6) {
            if let u = lastCodexLimits(in: file) { return u }
        }
        return nil
    }

    /// Codex files sessions under year/month/day folders; only the latest two days are looked at.
    private static func newestFiles(in root: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        func sortedDirs(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var days: [URL] = []
        outer: for y in sortedDirs(root) {
            for m in sortedDirs(y) {
                for d in sortedDirs(m) { days.append(d); if days.count == 2 { break outer } }
            }
        }
        let files = days.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return Array(files.sorted { mtime($0) > mtime($1) }.prefix(limit))
    }

    private static func lastCodexLimits(in file: URL) -> PlanUsage? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? h.readToEnd() else { return nil }
        let asOf = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: marker) != nil,
                  let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let rl = ((o["payload"] as? [String: Any])?["rate_limits"] ?? o["rate_limits"]) as? [String: Any]
            else { continue }
            if let id = rl["limit_id"] as? String, id != "codex" { continue }
            func window(_ key: String) -> UsageWindow? {
                guard let w = rl[key] as? [String: Any], let p = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                return UsageWindow(used: p / 100, resetsAt: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            }
            let u = PlanUsage(session: window("primary"), week: window("secondary"), asOf: asOf)
            if u.session != nil || u.week != nil { return u }
        }
        return nil
    }
}
