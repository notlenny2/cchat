import Foundation

/// Rolling copies of store.json in `backups/` next to it, so a bad save, a mistaken delete or an agent
/// editing the wrong thing can be undone. Hourly while chats change: every copy from the last two days, then
/// one a day for a month. Pictures and photos aren't copied (they're never rewritten, only added).
enum Backups {
    static var dir: URL {
        let d = Store.fileURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH"
        return f
    }()

    /// Copies the store if it changed since the newest copy and that copy is at least an hour old.
    static func takeIfDue(now: Date = Date()) {
        let fm = FileManager.default
        let src = Store.fileURL
        guard let data = try? Data(contentsOf: src), !data.isEmpty,
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return }   // never back up a broken file
        let existing = copies()
        if let newest = existing.first {
            if now.timeIntervalSince(newest.date) < 3600 { return }
            if (try? Data(contentsOf: newest.url)) == data { return }
        }
        let dest = dir.appendingPathComponent("store-\(stamp.string(from: now)).json")
        do {
            try data.write(to: dest, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            Log.info("backup saved \(dest.lastPathComponent)")
        } catch { Log.error("backup failed: \(error)") }
        prune(now: now)
    }

    /// Newest first.
    static func copies() -> [(url: URL, date: Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { u -> (URL, Date)? in
            let name = u.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("store-"), let d = stamp.date(from: String(name.dropFirst(6))) else { return nil }
            return (u, d)
        }.sorted { $0.1 > $1.1 }
    }

    static func prune(now: Date = Date()) {
        var keptDays = Set<String>()
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        for c in copies() {
            let age = now.timeIntervalSince(c.date)
            if age < 2 * 86400 { continue }
            let key = day.string(from: c.date)
            if age < 30 * 86400, keptDays.insert(key).inserted { continue }   // newest copy of each day
            try? FileManager.default.removeItem(at: c.url)
        }
    }
}
