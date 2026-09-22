import AppKit

/// Finds a project's own app icon so its contact photo is the real thing. Looks for an Xcode
/// AppIcon set first (skipping vendored code like JUCE, Pods, node_modules), then common web and
/// Android icon files. Returns nil for anything that isn't a real project folder (like the home folder).
enum IconFinder {
    private static let skipDirs: Set<String> = [
        "node_modules", "Pods", "build", ".build", "DerivedData", ".git", "JUCE", "vendor", "dist",
        ".next", "Carthage", "venv", ".venv", "site-packages", "Library", ".dart_tool", "ThirdParty",
        "third_party", "external", "deps", "out", ".vercel", "Intermediate", "Saved", "Binaries",
    ]
    private static let penalized = ["watch", "widget", "test", "example", "demo", "sample", "extension", "sticker"]
    private static let webNames: Set<String> = [
        "icon.png", "app_icon.png", "appicon.png", "apple-touch-icon.png", "logo.png", "favicon.png",
        "icon-512.png", "icon-192.png", "icon-512x512.png", "android-chrome-512x512.png", "ic_launcher.png",
    ]

    static func find(in folder: String, name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard folder != home, folder != "/", FileManager.default.fileExists(atPath: folder) else { return nil }
        let root = URL(fileURLWithPath: folder)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let tokens = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        var sets: [(URL, Int)] = []
        var files: [(URL, Int)] = []
        var visited = 0
        for case let url as URL in e {
            visited += 1
            if visited > 60_000 { break }
            let last = url.lastPathComponent
            if skipDirs.contains(last) { e.skipDescendants(); continue }
            if e.level > 7 { e.skipDescendants(); continue }
            let rel = url.path.dropFirst(root.path.count).lowercased()
            var score = 0
            if tokens.contains(where: { rel.contains($0) }) { score += 10 }
            if penalized.contains(where: { rel.contains($0) }) { score -= 20 }
            if rel.contains("ios") { score += 3 }
            score -= e.level
            if last == "AppIcon.appiconset" || last.hasSuffix(".appiconset") && last.lowercased().contains("appicon") {
                sets.append((url, score)); e.skipDescendants()
            } else if webNames.contains(last.lowercased()) {
                files.append((url, score - 5))
            }
        }
        for (set, _) in sets.sorted(by: { $0.1 > $1.1 }) {
            if let png = largestImage(in: set) { return png }
        }
        let ranked = files.compactMap { f -> (String, Int)? in
            guard let img = NSImage(contentsOf: f.0), let rep = img.representations.first, rep.pixelsWide >= 96 else { return nil }
            return (f.0.path, f.1 + min(rep.pixelsWide, 1024) / 128)
        }
        return ranked.max { $0.1 < $1.1 }?.0
    }

    private static func largestImage(in set: URL) -> String? {
        let items = (try? FileManager.default.contentsOfDirectory(at: set, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .max { size($0) < size($1) }?.path
    }

    private static func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
}

/// Keeps decoded contact photos in memory so the sidebar doesn't reread files while scrolling.
@MainActor
enum IconCache {
    private static var images: [String: NSImage] = [:]
    static func image(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        if let i = images[path] { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        images[path] = i
        return i
    }
}

extension Store {
    /// Looks up icons for any project contact that hasn't been searched yet. Runs off the main
    /// thread because it walks project folders.
    func findMissingIcons() {
        let todo = contacts.filter { !$0.isSubContact && $0.iconPath == nil && $0.iconSearched != true }
        guard !todo.isEmpty else { return }
        Task.detached(priority: .utility) {
            var found: [UUID: String?] = [:]
            for c in todo { found[c.id] = IconFinder.find(in: c.projectPath, name: c.name) }
            await MainActor.run {
                for (id, path) in found {
                    guard let i = self.contacts.firstIndex(where: { $0.id == id }) else { continue }
                    self.contacts[i].iconSearched = true
                    if let path { self.contacts[i].iconPath = path }
                    Log.info("icon for \(self.contacts[i].name): \(path ?? "none")")
                }
                self.save()
            }
        }
    }

    /// Sub-contacts wear their project's icon unless they have their own.
    func iconPath(for c: Contact) -> String? {
        c.iconPath ?? contact(c.parentId)?.iconPath
    }
}
