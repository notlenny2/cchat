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

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixed = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        let fromPath = loginPath.split(separator: ":").map { "\($0)/claude" }
        return (fixed + fromPath).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(prompt: String, cwd: String, sessionId: String?, systemPrompt: String,
                    model: String, fullAccess: Bool, fork: Bool = false, extraDirs: [String] = []) async throws -> ClaudeResult {
        guard let claude = claudePath else { throw RunnerError.claudeNotFound }
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
        guard let claude = claudePath else { throw RunnerError.claudeNotFound }
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
