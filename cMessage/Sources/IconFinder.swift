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
            // A project with a personal and a public icon (cChat itself) should wear the one that
            // matches this build: blue in a personal build, orange in the public one.
            #if CCHAT_PERSONAL
            if rel.contains("personal") { score += 8 }
            #else
            if rel.contains("personal") { score -= 8 }
            #endif
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
        guard let raw = NSImage(contentsOfFile: path) else { return nil }
        let i = trimmed(raw) ?? raw
        images[path] = i
        return i
    }

    /// Crops away a see-through border (a Mac app icon is a tile with empty space and a shadow around it),
    /// so the picture fills its circle. Mostly-clear pixels (the soft shadow) count as border.
    private static func trimmed(_ img: NSImage) -> NSImage? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.alphaInfo != .none, cg.alphaInfo != .noneSkipLast, cg.alphaInfo != .noneSkipFirst else { return nil }
        let w = min(cg.width, 256), h = min(cg.height, 256)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 200 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX > minX, maxY > minY, maxX - minX < w * 95 / 100 || maxY - minY < h * 95 / 100 else { return nil }
        // Back to the full-size image's pixels (the bitmap and CGImage cropping both count rows from the top).
        let sx = Double(cg.width) / Double(w), sy = Double(cg.height) / Double(h)
        let rect = CGRect(x: Double(minX) * sx, y: Double(minY) * sy,
                          width: Double(maxX - minX + 1) * sx, height: Double(maxY - minY + 1) * sy).integral
        guard let cut = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
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
        guard let p = c.iconPath ?? contact(c.parentId)?.iconPath else { return nil }
        return Self.matchingBuild(p)
    }

    /// A contact saved with one build's app icon (e.g. cChat's orange AppIcon) wears the icon set that
    /// matches the build running now, when the project has both side by side.
    nonisolated static func matchingBuild(_ path: String) -> String {
        let (from, to) = Flavor.personal ? ("/AppIcon.appiconset/", "/AppIconPersonal.appiconset/")
                                         : ("/AppIconPersonal.appiconset/", "/AppIcon.appiconset/")
        guard path.contains(from) else { return path }
        let swapped = path.replacingOccurrences(of: from, with: to)
        return FileManager.default.fileExists(atPath: swapped) ? swapped : path
    }
}
