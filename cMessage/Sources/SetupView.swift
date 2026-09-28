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
        if APIKeys.has(.claude) { return .ready }
        let out = await run(claude, ["auth", "status", "--json"])
        guard let data = out.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .signedOut }
        return (o["loggedIn"] as? Bool) == true ? .ready : .signedOut
    }

    static func codexState() async -> ToolState {
        guard let codex = ClaudeRunner.codexPath else { return .missing }
        if APIKeys.has(.codex) { return .ready }
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

    /// Gemini CLI has no "am I signed in" command, so this reads what its own login flow leaves behind:
    /// the auth choice in ~/.gemini/settings.json, Google sign-in tokens, or an API key in ~/.gemini/.env.
    static func geminiState() async -> ToolState {
        guard ClaudeRunner.geminiPath != nil else { return .missing }
        if APIKeys.has(.gemini) { return .ready }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        if let d = try? Data(contentsOf: home.appendingPathComponent("settings.json")),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let auth = (o["security"] as? [String: Any])?["auth"] as? [String: Any],
           let t = auth["selectedType"] as? String, !t.isEmpty { return .ready }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent("oauth_creds.json").path) { return .ready }
        if let env = try? String(contentsOf: home.appendingPathComponent(".env"), encoding: .utf8),
           env.contains("GEMINI_API_KEY=") { return .ready }
        if ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil { return .ready }
        return .signedOut
    }
    /// Gemini's sign-in is its own first-run screen (Google account or API key), so this just opens it.
    static func signInGemini() {
        guard let p = ClaudeRunner.geminiPath else { return }
        terminal("\(quote(p))", title: "Signing in to Gemini (pick how to sign in, then type /quit when it's done)")
    }
    /// Homebrew if it's here, else npm; both are Google's documented ways.
    static var canInstallGemini: Bool { brewPath != nil || npmPath != nil }
    static func installGemini() {
        if let b = brewPath { terminal("\(quote(b)) install gemini-cli", title: "Installing Gemini CLI") }
        else if let n = npmPath { terminal("\(quote(n)) install -g @google/gemini-cli", title: "Installing Gemini CLI") }
        else { learnGemini() }
    }
    /// `grok models` says "You are not authenticated" until `grok login` (or an XAI_API_KEY) is set up.
    static func grokState() async -> ToolState {
        guard let g = ClaudeRunner.grokPath else { return .missing }
        if APIKeys.has(.grok) { return .ready }
        if ProcessInfo.processInfo.environment["XAI_API_KEY"] != nil { return .ready }
        let out = await run(g, ["models"])
        return out.localizedCaseInsensitiveContains("not authenticated") ? .signedOut : .ready
    }
    static func installGrok() { terminal("curl -fsSL https://x.ai/cli/install.sh | bash", title: "Installing Grok") }
    static func signInGrok() {
        guard let p = ClaudeRunner.grokPath else { return }
        terminal("\(quote(p)) login", title: "Signing in to Grok")
    }
    static func learnGrok() { NSWorkspace.shared.open(URL(string: "https://docs.x.ai/build/overview")!) }
    static func learnGemini() { NSWorkspace.shared.open(URL(string: "https://github.com/google-gemini/gemini-cli")!) }
    private static var brewPath: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    private static var npmPath: String? {
        (["/opt/homebrew/bin/npm", "/usr/local/bin/npm"] + ClaudeRunner.loginPath.split(separator: ":").map { "\($0)/npm" })
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

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
    @State private var gemini: ToolState = .checking
    @State private var grok: ToolState = .checking
    @State private var phoneLink = Prefs.phoneLink

    private var welcome: Bool { onDone != nil }

    var body: some View {
        // Seven rows plus key boxes can outgrow a laptop screen, so it scrolls.
        ScrollView {
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
                APIKeyField(engine: .claude)
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
                APIKeyField(engine: .codex)
            }

            row("4", "Gemini (optional), Google's agent") {
                HStack(spacing: 10) {
                    status(gemini, ready: "Installed and signed in", missing: "Not installed")
                    switch gemini {
                    case .missing:
                        if Tools.canInstallGemini { Button("Install Gemini CLI", action: Tools.installGemini) }
                        Button("Learn More", action: Tools.learnGemini)
                    case .signedOut: Button("Sign In", action: Tools.signInGemini)
                    default: EmptyView()
                    }
                }
                Text("Free with a Google account. Signing in happens in a Terminal window; cChat never sees your password.")
                APIKeyField(engine: .gemini)
                    .font(.caption).foregroundStyle(Clay.inkSoft)
            }

            row("5", "Grok (optional), xAI's agent") {
                HStack(spacing: 10) {
                    status(grok, ready: "Installed and signed in", missing: "Not installed")
                    switch grok {
                    case .missing:
                        Button("Install Grok", action: Tools.installGrok)
                        Button("Learn More", action: Tools.learnGrok)
                    case .signedOut: Button("Sign In", action: Tools.signInGrok)
                    default: EmptyView()
                    }
                }
                Text("Needs a SuperGrok or X Premium+ plan, or an xAI API key. Signing in happens in a Terminal window.")
                APIKeyField(engine: .grok)
                    .font(.caption).foregroundStyle(Clay.inkSoft)
            }

            row("6", "Where do your projects live?") {
                HStack(spacing: 10) {
                    Label(short(folder), systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: pickFolder)
                }
                Text("Every folder in here can be texted. New projects you start from cChat go here too.")
                    .font(.caption).foregroundStyle(Clay.inkSoft)
            }

            if !welcome {
                row("7", "iPhone and iPad") {
                    Toggle("Let my iPhone or iPad link to this Mac", isOn: Binding(
                        get: { phoneLink },
                        set: { on in
                            phoneLink = on
                            if on { RemoteServer.shared.newPairing() } else { RemoteServer.shared.unpair() }
                        }))
                    if phoneLink {
                        Button("Show Code to Scan") { NotificationCenter.default.post(name: .showPairing, object: nil) }
                    }
                    Text("Works on the same Wi-Fi. Only a device that scanned your code can get in. Switching this off unlinks every device.")
                        .font(.caption).foregroundStyle(Clay.inkSoft)
                }
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
        }
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 760, maxHeight: 900)
        .background(Clay.canvas)
        // Keeps checking while it's open, so it flips to "signed in" by itself once Terminal is done.
        .task {
            while !Task.isCancelled {
                let c = await Tools.claudeState(), x = await Tools.codexState(), g = await Tools.geminiState(), k = await Tools.grokState()
                claude = c; codex = x; gemini = g; grok = k
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


/// "Use an API key instead": pay-per-use for people without a plan (or who'd rather). The key goes into the
/// Keychain (see APIKeys) and is only ever handed to that engine's own command-line tool.
struct APIKeyField: View {
    let engine: Engine
    @State private var saved = false
    @State private var open = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if saved {
                HStack(spacing: 8) {
                    Label("Using your \(engine.label) API key", systemImage: "key.fill").font(.caption).foregroundStyle(Clay.ink)
                    Button("Remove") { APIKeys.set(nil, for: engine); saved = false }.controlSize(.small)
                }
                Text("Charged per use to that account, not your plan. Remove it to go back to signing in.")
                    .font(.caption2).foregroundStyle(Clay.inkSoft)
            } else if open {
                HStack(spacing: 8) {
                    SecureField("Paste your \(engine.label) API key", text: $draft).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        .onSubmit(save)
                    Button("Save", action: save).controlSize(.small).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { open = false; draft = "" }.controlSize(.small)
                }
                Link("Get a key", destination: APIKeys.consoleURL(engine)).font(.caption)
            } else {
                Button("Use an API key instead") { open = true }.buttonStyle(.link).font(.caption)
            }
        }
        .onAppear { saved = APIKeys.has(engine) }
    }

    private func save() {
        if APIKeys.set(draft, for: engine) { saved = true }
        open = false; draft = ""
    }
}
