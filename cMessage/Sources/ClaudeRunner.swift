import Foundation

struct ClaudeResult {
    var text: String
    var sessionId: String?
    var deniedTools: [String]
    var isError: Bool
}

enum RunnerError: LocalizedError {
    case claudeNotFound
    case folderMissing(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .claudeNotFound: return "Couldn't find Claude Code on this Mac."
        case .folderMissing(let p): return "The project folder is gone: \(p)"
        case .failed(let s): return s
        }
    }
}

/// Runs one turn of a Claude Code agent headlessly (`claude -p --output-format json`) and hands
/// back only the final reply text. The prompt goes in on stdin, never argv, so nothing a user
/// types can be read as a CLI flag.
enum ClaudeRunner {
    /// The user's login-shell PATH, so the agent's own tools (git, npm, flutter...) resolve the
    /// same way they do in Terminal. A Finder-launched app otherwise gets a bare PATH.
    static let loginPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "echo -n $PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !s.isEmpty { return s }
        } catch { Log.error("login PATH lookup failed: \(error)") }
        return "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    /// Where Claude Code and Codex live. Both update themselves by reinstalling, which leaves the command
    /// missing for a few seconds; a turn landing in that gap failed with "Couldn't find Claude Code"
    /// (2026-09-22, twice). The last place each was seen is remembered, looked for again if it's gone, and
    /// a turn waits up to ~45s for it to come back before giving up.
    private static let claudeSpots: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
    }()
    private static let codexSpots = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    private static let pathLock = NSLock()
    private static var seen: [String: String] = [:]

    private static func locate(_ name: String, _ spots: [String]) -> String? {
        pathLock.lock(); defer { pathLock.unlock() }
        let fm = FileManager.default
        if let p = seen[name], fm.isExecutableFile(atPath: p) { return p }
        let found = (spots + loginPath.split(separator: ":").map { "\($0)/\(name)" }).first { fm.isExecutableFile(atPath: $0) }
        if let found { seen[name] = found }
        return found
    }

    private static func waitFor(_ name: String, _ spots: [String]) async -> String? {
        for attempt in 0..<16 {
            if let p = locate(name, spots) {
                if attempt > 0 { Log.info("\(name) is back (probably finished updating)") }
                return p
            }
            if attempt == 0 { Log.info("\(name) missing, waiting for it (probably updating)") }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return nil
    }

    static var claudePath: String? { locate("claude", claudeSpots) }

    static func run(prompt: String, cwd: String, sessionId: String?, systemPrompt: String,
                    model: String, fullAccess: Bool, fork: Bool = false, extraDirs: [String] = []) async throws -> ClaudeResult {
        guard let claude = await waitFor("claude", claudeSpots) else { throw RunnerError.claudeNotFound }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw RunnerError.folderMissing(cwd)
        }

        var args = ["-p", "--output-format", "json",
                    "--append-system-prompt", systemPrompt,
                    "--permission-mode", fullAccess ? "bypassPermissions" : "acceptEdits"]
        if let sessionId { args += ["--resume", sessionId] + (fork ? ["--fork-session"] : []) }
        if !model.isEmpty { args += ["--model", model] }
        // Lets the agent open pictures the user dragged in, which live outside the project folder.
        for d in extraDirs { args += ["--add-dir", d] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain both pipes as data arrives so a long reply can't fill the buffer and deadlock.
        let outBuf = DataBox(), errBuf = DataBox()
        stdout.fileHandleForReading.readabilityHandler = { outBuf.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errBuf.append($0.availableData) }

        Log.info("run \(URL(fileURLWithPath: cwd).lastPathComponent) resume=\(sessionId ?? "new") model=\(model.isEmpty ? "default" : model) full=\(fullAccess)")

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                    stdin.fileHandleForWriting.write(prompt.data(using: .utf8) ?? Data())
                    try? stdin.fileHandleForWriting.close()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        outBuf.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errBuf.append(stderr.fileHandleForReading.readDataToEndOfFile())

        if Task.isCancelled { throw CancellationError() }

        let raw = outBuf.data
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            let err = String(data: errBuf.data, encoding: .utf8) ?? ""
            let out = String(data: raw, encoding: .utf8) ?? ""
            Log.error("unparseable output (exit \(status)) stderr=\(err.prefix(800)) stdout=\(out.prefix(800))")
            throw RunnerError.failed(firstLine(err.isEmpty ? out : err) ?? "Claude Code exited with code \(status).")
        }

        let denied = (obj["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
        let isError = (obj["is_error"] as? Bool) ?? (status != 0)
        let text = (obj["result"] as? String) ?? ""
        if isError { Log.error("agent error: \(text.prefix(800))") }
        return ClaudeResult(text: text, sessionId: obj["session_id"] as? String, deniedTools: denied, isError: isError)
    }

    /// A quick, tool-less, memory-less call used for small decisions (like who in a group should
    /// answer). Skips the user's settings, CLAUDE.md files and MCP servers so it costs a fraction of a cent.
    static func quick(prompt: String, system: String, model: String = "haiku") async throws -> String {
        guard let claude = await waitFor("claude", claudeSpots) else { throw RunnerError.claudeNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--output-format", "json", "--model", model, "--tools", "",
                             "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
                             "--system-prompt", system]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        let outBuf = DataBox()
        stdout.fileHandleForReading.readabilityHandler = { outBuf.append($0.availableData) }
        let _: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(prompt.data(using: .utf8) ?? Data())
                try? stdin.fileHandleForWriting.close()
            } catch { process.terminationHandler = nil; cont.resume(throwing: error) }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        outBuf.append(stdout.fileHandleForReading.readDataToEndOfFile())
        guard let o = try? JSONSerialization.jsonObject(with: outBuf.data) as? [String: Any],
              let r = o["result"] as? String else { throw RunnerError.failed("Quick call returned nothing") }
        return r
    }

    /// Codex's own list of models (the ones it shows in its picker), newest first.
    static var codexModels: [ModelOption] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        var out = [ModelOption(id: "", label: "Default", note: "Whatever Codex normally uses")]
        if let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let ms = o["models"] as? [[String: Any]] {
            for m in ms where (m["visibility"] as? String) == "list" {
                if let slug = m["slug"] as? String {
                    out.append(ModelOption(id: slug, label: (m["display_name"] as? String) ?? slug,
                                           note: (m["description"] as? String) ?? ""))
                }
            }
        }
        return out
    }

    static var codexPath: String? { locate("codex", codexSpots) }

    /// One turn of an OpenAI Codex agent (`codex exec --json`), shaped like a Claude result so the
    /// rest of the app doesn't care which one answered. Codex has no system-prompt flag, so cChat's
    /// house rules ride at the top of the message, clearly marked as coming from the app.
    static func runCodex(prompt: String, cwd: String, threadId: String?, instructions: String,
                         fullAccess: Bool, images: [String], model: String? = nil) async throws -> ClaudeResult {
        guard let codex = await waitFor("codex", codexSpots) else { throw RunnerError.failed("Couldn't find Codex on this Mac.") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw RunnerError.folderMissing(cwd)
        }
        var args = ["exec"]
        if let threadId { args += ["resume", threadId] }
        args += ["--json", "--skip-git-repo-check"]
        args += fullAccess ? ["--dangerously-bypass-approvals-and-sandbox"] : ["-c", "sandbox_mode=\"workspace-write\""]
        if let model, !model.isEmpty { args += ["-m", model] }
        for img in images { args += ["-i", img] }
        args.append("-")
        let full = "[cChat app instructions, not from the user]\n\(instructions)\n[end of app instructions]\n\n\(prompt)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let outBuf = DataBox(), errBuf = DataBox()
        stdout.fileHandleForReading.readabilityHandler = { outBuf.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errBuf.append($0.availableData) }
        Log.info("codex \(URL(fileURLWithPath: cwd).lastPathComponent) resume=\(threadId ?? "new") full=\(fullAccess) images=\(images.count)")

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                    stdin.fileHandleForWriting.write(full.data(using: .utf8) ?? Data())
                    try? stdin.fileHandleForWriting.close()
                } catch { process.terminationHandler = nil; cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        outBuf.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errBuf.append(stderr.fileHandleForReading.readDataToEndOfFile())
        if Task.isCancelled { throw CancellationError() }

        var thread = threadId, messages: [String] = [], errors: [String] = []
        for line in outBuf.data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "thread.started": thread = (o["thread_id"] as? String) ?? thread
            case "item.completed":
                if let item = o["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let t = item["text"] as? String, !t.isEmpty { messages.append(t) }
            case "error", "turn.failed":
                let msg = (o["message"] as? String) ?? ((o["error"] as? [String: Any])?["message"] as? String) ?? "Codex hit an error."
                errors.append(msg)
            default: break
            }
        }
        if messages.isEmpty {
            let err = errors.last ?? firstLine(String(decoding: errBuf.data, as: UTF8.self)) ?? "Codex exited with code \(status)."
            Log.error("codex failed (exit \(status)): \(err.prefix(800))")
            return ClaudeResult(text: err, sessionId: thread, deniedTools: [], isError: true)
        }
        return ClaudeResult(text: messages.joined(separator: "\n\n"), sessionId: thread, deniedTools: [], isError: false)
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    func append(_ d: Data) { lock.lock(); buf.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buf }
}
