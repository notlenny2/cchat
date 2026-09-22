import SwiftUI
import AppKit

/// Is a helper app (Claude Code, Codex) here, and is it signed in?
enum ToolState: Equatable {
    case checking, missing, signedOut, ready
}

/// Checks and signs in the agent apps cChat drives. Signing in happens in Terminal, in the tool's own
/// login flow, so cChat never sees a password or a token: it only asks each tool "are you signed in?".
enum Tools {
    static func claudeState() async -> ToolState {
        guard let claude = ClaudeRunner.claudePath else { return .missing }
        let out = await run(claude, ["auth", "status", "--json"])
        guard let data = out.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .signedOut }
        return (o["loggedIn"] as? Bool) == true ? .ready : .signedOut
    }

    static func codexState() async -> ToolState {
        guard let codex = ClaudeRunner.codexPath else { return .missing }
        let out = await run(codex, ["login", "status"])
        return out.localizedCaseInsensitiveContains("logged in") && !out.localizedCaseInsensitiveContains("not logged in") ? .ready : .signedOut
    }

    /// The official Claude Code installer, for Macs that don't have it yet.
    static func installClaude() { terminal("curl -fsSL https://claude.ai/install.sh | bash", title: "Installing Claude Code") }
    static func signInClaude() {
        guard let p = ClaudeRunner.claudePath else { return }
        terminal("\(quote(p)) auth login", title: "Signing in to Claude")
    }
    static func signInCodex() {
        guard let p = ClaudeRunner.codexPath else { return }
        terminal("\(quote(p)) login", title: "Signing in to Codex")
    }
    static func learnCodex() { NSWorkspace.shared.open(URL(string: "https://github.com/openai/codex")!) }

    /// Opens Terminal running one fixed command (no user text ever goes into it), via a throwaway
    /// .command file, so no Automation permission is needed.
    private static func terminal(_ command: String, title: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cchat-\(UUID().uuidString).command")
        let script = """
        #!/bin/zsh -l
        clear
        echo "\(title)…"
        echo
        \(command)
        echo
        echo "All done. You can close this window and go back to cChat."
        rm -f \(quote(url.path))
        """
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { Log.error("couldn't open Terminal for \(title): \(error)") }
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func run(_ exe: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ClaudeRunner.loginPath
            env.removeValue(forKey: "CLAUDECODE")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.terminationHandler = { _ in
                cont.resume(returning: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { p.terminationHandler = nil; cont.resume(returning: "") }
        }
    }
}

/// First-run welcome for the public release, and cChat > Settings for everyone: your name, Claude Code
/// (installed and signed in), Codex (optional), and the folder your projects live in.
struct SetupView: View {
    /// nil when shown as Settings; the welcome screen passes what to do when it's finished.
    var onDone: (() -> Void)?

    @State private var name = Prefs.userName
    @State private var folder = Prefs.projectsRoot
    @State private var claude: ToolState = .checking
    @State private var codex: ToolState = .checking

    private var welcome: Bool { onDone != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if welcome {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to cChat").font(.title.bold())
                        Text("Text your projects like friends. AI agents do the work and answer in plain English.")
                            .foregroundStyle(Clay.inkSoft)
                    }
                }
            }

            row("1", "What should your agents call you?") {
                TextField("Your name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit(save)
            }

            row("2", "Claude Code, the agent that does the work") {
                HStack(spacing: 10) {
                    status(claude, ready: "Installed and signed in")
                    switch claude {
                    case .missing: Button("Install Claude Code", action: Tools.installClaude).buttonStyle(.borderedProminent)
                    case .signedOut: Button("Sign In", action: Tools.signInClaude).buttonStyle(.borderedProminent)
                    default: EmptyView()
                    }
                }
                Text("Uses your own Claude account and plan. Signing in happens in a Terminal window; cChat never sees your password.")
                    .font(.caption).foregroundStyle(Clay.inkSoft)
            }

            row("3", "Codex (optional), OpenAI's agent") {
                HStack(spacing: 10) {
                    status(codex, ready: "Installed and signed in", missing: "Not installed")
                    switch codex {
                    case .missing: Button("Learn More", action: Tools.learnCodex)
                    case .signedOut: Button("Sign In", action: Tools.signInCodex)
                    default: EmptyView()
                    }
                }
            }

            row("4", "Where do your projects live?") {
                HStack(spacing: 10) {
                    Label(short(folder), systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: pickFolder)
                }
                Text("Every folder in here can be texted. New projects you start from cChat go here too.")
                    .font(.caption).foregroundStyle(Clay.inkSoft)
            }

            HStack {
                Spacer()
                if welcome {
                    if claude != .ready {
                        Button("Finish Later") { finish() }
                    }
                    Button("Start Texting") { finish() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(claude != .ready || name.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(Clay.canvas)
        // Keeps checking while it's open, so it flips to "signed in" by itself once Terminal is done.
        .task {
            while !Task.isCancelled {
                let c = await Tools.claudeState(), x = await Tools.codexState()
                claude = c; codex = x
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func row<Content: View>(_ n: String, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(.headline).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(ClaySurface(shape: Circle(), color: Clay.terracotta, depth: 0.7))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(Clay.ink)
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .clay(Clay.cream, radius: 16, depth: 0.6)
    }

    @ViewBuilder
    private func status(_ s: ToolState, ready: String, missing: String = "Not installed yet") -> some View {
        switch s {
        case .checking: ProgressView().controlSize(.small)
        case .missing: Label(missing, systemImage: "xmark.circle").foregroundStyle(Clay.inkSoft)
        case .signedOut: Label("Installed, not signed in", systemImage: "person.crop.circle.badge.questionmark").foregroundStyle(Clay.inkSoft)
        case .ready: Label(ready, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func short(_ u: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return u.path.hasPrefix(home) ? "~" + u.path.dropFirst(home.count) : u.path
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.directoryURL = FileManager.default.fileExists(atPath: folder.path) ? folder : FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let u = panel.url { folder = u; save() }
    }

    private func save() {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { Prefs.userName = name }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Prefs.projectsRoot = folder
    }

    private func finish() {
        save()
        Prefs.setupDone = true
        onDone?()
    }
}
