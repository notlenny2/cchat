import AppKit

/// Installs a newer build of cChat by itself, but only when it's safe: no agent is mid-reply (so every
/// answer is already saved) and the user hasn't typed anything for a minute (so no half-written message is lost).
/// Replaces the old "outside helper waits for a process to exit" approach, which once guessed wrong and
/// restarted the app on top of a reply.
@MainActor
enum SelfUpdate {
    /// The personal build installs itself from this repo's own build folder, wherever the repo lives.
    #if CCHAT_PERSONAL
    static let buildURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("build/Build/Products/Release/cChat.app")
    #else
    static let buildURL = URL(fileURLWithPath: "/nonexistent")
    #endif
    private static var quietSince: Date?
    private static var timer: Timer?

    static func start(_ store: Store) {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { check(store) }
        }
    }

    private static func mtime(_ app: URL) -> Date? {
        let exe = app.appendingPathComponent("Contents/MacOS/cChat")
        return (try? exe.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func check(_ store: Store) {
        guard let mine = mtime(Bundle.main.bundleURL), let theirs = mtime(buildURL), theirs > mine.addingTimeInterval(5) else { return }
        // Only ever swap in this same app, never the public build if it lands in the same folder.
        guard Bundle(url: buildURL)?.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
        let busy = store.conversations.contains { store.isBusy($0.id) }
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        guard !busy, sinceKey > 60 else { quietSince = nil; return }
        if quietSince == nil { quietSince = Date(); return }
        guard Date().timeIntervalSince(quietSince!) > 20 else { return }
        install(store)
    }

    private static func install(_ store: Store) {
        store.save()
        let me = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf '\(me)' && cp -R '\(buildURL.path)' '\(me)' && open '\(me)'
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Detached with nohup so it outlives the app it's replacing.
        let inner = script.replacingOccurrences(of: "'", with: "'\\''")
        p.arguments = ["-c", "nohup /bin/zsh -c '\(inner)' >/dev/null 2>&1 &"]
        do {
            try p.run()
            Log.info("self-update: installing newer build and relaunching")
            NSApp.terminate(nil)
        } catch { Log.error("self-update failed to start: \(error)") }
    }
}
