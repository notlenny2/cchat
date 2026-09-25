import Foundation

struct ClaudeResult {
    var text: String
    var sessionId: String?
    var deniedTools: [String]
    var isError: Bool
    /// The biggest memory the model that answered can hold (1M or 200k tokens), from Claude's own report.
    var contextWindow: Int? = nil
}

enum RunnerError: LocalizedError {
    case claudeNotFound
    case folderMissing(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .claudeNotFound: return Flavor.personal ? "Couldn't find Claude Code on this Mac." : "Couldn't find Claude Code on this Mac. Open cChat > Settings to install it."
        case .folderMissing(let p): return "The project folder is gone: \(p)"
        case .failed(let s): return s
        }
    }
}

/// Runs one turn of a Claude Code agent headlessly (`claude -p --output-format stream-json`) and hands
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
                    model: String, fullAccess: Bool, fork: Bool = false, extraDirs: [String] = [],
                    onStep: (@Sendable (WorkStep) -> Void)? = nil) async throws -> ClaudeResult {
        guard let claude = await waitFor("claude", claudeSpots) else { throw RunnerError.claudeNotFound }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw RunnerError.folderMissing(cwd)
        }

        var args = ["-p", "--output-format", "stream-json", "--verbose",
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
        let feed = LineFeed { line in onStep.map { cb in claudeSteps(line).forEach(cb) } }
        stdout.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            outBuf.append(d)
            if onStep != nil { feed.append(d) }
        }
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
        guard let obj = finalResult(raw) else {
            let err = String(data: errBuf.data, encoding: .utf8) ?? ""
            let out = String(data: raw, encoding: .utf8) ?? ""
            Log.error("unparseable output (exit \(status)) stderr=\(err.prefix(800)) stdout=\(out.prefix(800))")
            throw RunnerError.failed(firstLine(err.isEmpty ? out : err) ?? "Claude Code exited with code \(status).")
        }

        let denied = (obj["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
        let isError = (obj["is_error"] as? Bool) ?? (status != 0)
        let text = (obj["result"] as? String) ?? ""
        if isError { Log.error("agent error: \(text.prefix(800))") }
        let window = (obj["modelUsage"] as? [String: [String: Any]])?.values.compactMap { $0["contextWindow"] as? Int }.max()
        return ClaudeResult(text: text, sessionId: obj["session_id"] as? String, deniedTools: denied, isError: isError,
                            contextWindow: window)
    }

    /// A quick, tool-less, memory-less call used for small decisions (like who in a group should
    /// answer). Skips the user's settings, CLAUDE.md files and MCP servers so it costs a fraction of a cent.
    static func quick(prompt: String, system: String, model: String = "haiku") async throws -> String {
        guard let claude = await waitFor("claude", claudeSpots) else { throw RunnerError.claudeNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--model", model, "--tools", "",
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
        guard let o = finalResult(outBuf.data), let r = o["result"] as? String else { throw RunnerError.failed("Quick call returned nothing") }
        return r
    }

    /// Told whenever Claude Code reports how much of the plan is used (every turn, on its own).
    nonisolated(unsafe) static var onUsage: (@Sendable (PlanUsage) -> Void)?

    /// Claude Code's stream output is one JSON object per line; the last `result` line is the reply
    /// (same shape as `--output-format json`). Plan usage rides along as a `rate_limit_event` line.
    private static func finalResult(_ data: Data) -> [String: Any]? {
        var result: [String: Any]?, usage: PlanUsage?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "result": result = o
            case "rate_limit_event": usage = UsageWatch.claude(o) ?? usage
            default: break
            }
        }
        if let usage { onUsage?(usage) }
        return result
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
        // Codex leaves some models out of its own list even for accounts that can use them (GPT-6 Astra,
        // 2026-09: missing from models_cache.json yet `codex exec -m gpt-6-astra` works on the author's plan).
        for extra in codexHidden where !out.contains(where: { $0.id == extra.id }) { out.insert(extra, at: 1) }
        return out
    }

    static let codexHidden = [ModelOption(id: "gpt-6-astra", label: "GPT-6 Astra",
                                          note: "OpenAI's newest; only works if your ChatGPT plan includes it")]

    static var codexPath: String? { locate("codex", codexSpots) }

    /// One turn of an OpenAI Codex agent (`codex exec --json`), shaped like a Claude result so the
    /// rest of the app doesn't care which one answered. Codex has no system-prompt flag, so cChat's
    /// house rules ride at the top of the message, clearly marked as coming from the app.
    static func runCodex(prompt: String, cwd: String, threadId: String?, instructions: String,
                         fullAccess: Bool, images: [String], model: String? = nil,
                         onStep: (@Sendable (WorkStep) -> Void)? = nil) async throws -> ClaudeResult {
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
        let full = "[cChat app instructions, not from \(Prefs.userName)]\n\(instructions)\n[end of app instructions]\n\n\(prompt)"

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
        let feed = LineFeed { line in onStep.map { cb in codexSteps(line).forEach(cb) } }
        stdout.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            outBuf.append(d)
            if onStep != nil { feed.append(d) }
        }
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

    // MARK: Show the Work

    /// Turns one line of Claude Code's stream into steps: tools it called, what they returned, its thinking and
    /// in-between remarks.
    static func claudeSteps(_ line: Data) -> [WorkStep] {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        switch (o["type"] as? String, o["subtype"] as? String) {
        case ("system", "init"):
            let bits = [(o["claude_code_version"] as? String).map { "Claude Code \($0)" }, o["model"] as? String,
                        o["permissionMode"] as? String, (o["session_id"] as? String).map { "session \($0.prefix(8))" },
                        (o["mcp_servers"] as? [Any]).map { "\($0.count) MCP servers" }].compactMap { $0 }
            return [WorkStep(kind: .info, text: bits.joined(separator: " · "))]
        case ("system", "hook_response"):
            let said = ((o["output"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let head = "\(o["hook_name"] as? String ?? "hook") hook \(o["outcome"] as? String ?? "ran")"
            return [WorkStep(kind: .info, text: WorkStep.clip(said.isEmpty ? head : "\(head): \(said)", 1200),
                             failed: (o["exit_code"] as? Int ?? 0) != 0 ? true : nil)]
        case ("system", "compact_boundary"):
            return [WorkStep(kind: .info, text: "Conversation compacted")]
        case ("result", _):
            return [WorkStep(kind: .info, text: tally(o), failed: (o["is_error"] as? Bool) == true ? true : nil)]
        default: break
        }
        guard let msg = o["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] else { return [] }
        // Steps taken by a helper agent carry the id of the Task/Agent call that started it.
        let sub: Bool? = (o["parent_tool_use_id"] as? String) != nil ? true : nil
        var out: [WorkStep] = []
        for b in blocks {
            switch (o["type"] as? String, b["type"] as? String) {
            case ("assistant", "tool_use"):
                let name = b["name"] as? String ?? "Tool"
                out.append(WorkStep(kind: .tool, title: name, text: WorkStep.clip(describe(name, b["input"] as? [String: Any] ?? [:]), 4000),
                                    ref: b["id"] as? String, sub: sub))
            case ("assistant", "text"):
                if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(WorkStep(kind: .note, text: WorkStep.clip(t), sub: sub))
                }
            case ("assistant", "thinking"):
                if let t = b["thinking"] as? String, !t.isEmpty { out.append(WorkStep(kind: .thinking, text: WorkStep.clip(t), sub: sub)) }
            case ("assistant", "redacted_thinking"):
                out.append(WorkStep(kind: .thinking, text: "(thinking hidden)", sub: sub))
            case ("user", "tool_result"):
                var text = ""
                if let s = b["content"] as? String { text = s }
                else if let parts = b["content"] as? [[String: Any]] {
                    text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : "[picture]" }.joined(separator: "\n")
                }
                out.append(WorkStep(kind: .output, text: WorkStep.clip(text.isEmpty ? "(no output)" : text),
                                    failed: (b["is_error"] as? Bool) == true ? true : nil, ref: b["tool_use_id"] as? String, sub: sub))
            default: break
            }
        }
        return out
    }

    /// The end-of-turn line: how long, how many round trips, tokens in and out, what it cost.
    private static func tally(_ o: [String: Any]) -> String {
        var bits: [String] = []
        if let ms = o["duration_ms"] as? Double { bits.append(String(format: "Done in %.1fs", ms / 1000)) }
        if let n = o["num_turns"] as? Int { bits.append("\(n) turn\(n == 1 ? "" : "s")") }
        if let u = o["usage"] as? [String: Any] {
            func n(_ k: String) -> Int { u[k] as? Int ?? 0 }
            let cached = n("cache_read_input_tokens")
            let input = n("input_tokens") + n("cache_creation_input_tokens") + cached
            bits.append("\(tokens(input)) in" + (cached > 0 ? " (\(tokens(cached)) cached)" : ""))
            bits.append("\(tokens(n("output_tokens"))) out")
        }
        if let c = o["total_cost_usd"] as? Double { bits.append(String(format: "$%.3f", c)) }
        if let r = o["terminal_reason"] as? String, r != "completed" { bits.append(r) }
        return bits.isEmpty ? "Done" : bits.joined(separator: " · ")
    }

    private static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }

    /// What a tool call was, in full, the way verbose mode shows it: the command (with its description), the edit as
    /// a before/after, the file written, every search option.
    private static func describe(_ tool: String, _ input: [String: Any]) -> String {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func diff(_ old: String, _ new: String) -> String {
            (old.split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
             + new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }).joined(separator: "\n")
        }
        switch tool {
        case "Bash":
            var t = s("command") ?? ""
            if let d = s("description") { t += "\n# \(d)" }
            if input["run_in_background"] as? Bool == true { t += "\n# in the background" }
            return t
        case "Read":
            var t = s("file_path") ?? ""
            if let off = input["offset"] as? Int { t += " from line \(off)" }
            if let lim = input["limit"] as? Int { t += ", \(lim) lines" }
            if let p = s("pages") { t += " pages \(p)" }
            return t
        case "Edit":
            return [s("file_path") ?? "", input["replace_all"] as? Bool == true ? "(every match)" : nil,
                    diff(s("old_string") ?? "", s("new_string") ?? "")].compactMap { $0 }.joined(separator: "\n")
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).map { diff($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
            return ([s("file_path") ?? ""] + edits).joined(separator: "\n")
        case "Write":
            return "\(s("file_path") ?? "")\n" + (s("content") ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                .map { "+ \($0)" }.joined(separator: "\n")
        case "NotebookEdit":
            return [s("notebook_path"), s("edit_mode"), s("cell_id").map { "cell \($0)" }, s("new_source")].compactMap { $0 }.joined(separator: "\n")
        case "Grep":
            var t = [s("pattern"), s("path").map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
            let opts = ["glob", "type", "output_mode"].compactMap { k in s(k).map { "\(k)=\($0)" } }
                + ["-i", "-n", "multiline"].filter { input[$0] as? Bool == true }
                + ["-A", "-B", "-C", "head_limit"].compactMap { k in (input[k] as? Int).map { "\(k)=\($0)" } }
            if !opts.isEmpty { t += "  (" + opts.joined(separator: " ") + ")" }
            return t
        case "Glob": return [s("pattern"), s("path").map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
        case "WebFetch": return [s("url"), s("prompt")].compactMap { $0 }.joined(separator: "\n")
        case "WebSearch": return s("query") ?? ""
        case "Task", "Agent":
            return [s("description"), s("subagent_type").map { "(\($0))" }, s("prompt")].compactMap { $0 }.joined(separator: "\n")
        case "TodoWrite":
            return (input["todos"] as? [[String: Any]] ?? []).compactMap { t in
                (t["content"] as? String).map { c in
                    let box = ["completed": "[x]", "in_progress": "[~]"][t["status"] as? String ?? ""] ?? "[ ]"
                    return "\(box) \(c)"
                }
            }.joined(separator: "\n")
        default:
            let d = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: d, as: UTF8.self)
        }
    }

    /// Same for Codex's `--json` events.
    static func codexSteps(_ line: Data) -> [WorkStep] {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        switch o["type"] as? String {
        case "thread.started":
            return [WorkStep(kind: .info, text: "Codex session \((o["thread_id"] as? String ?? "").prefix(8))")]
        case "turn.completed":
            let u = o["usage"] as? [String: Any] ?? [:]
            func n(_ k: String) -> Int { u[k] as? Int ?? 0 }
            let cached = n("cached_input_tokens")
            return [WorkStep(kind: .info, text: "Done · \(tokens(n("input_tokens"))) in" + (cached > 0 ? " (\(tokens(cached)) cached)" : "")
                             + " · \(tokens(n("output_tokens"))) out")]
        case "turn.failed", "error":
            let msg = (o["message"] as? String) ?? ((o["error"] as? [String: Any])?["message"] as? String) ?? "Codex hit an error."
            return [WorkStep(kind: .info, text: msg, failed: true)]
        default: break
        }
        guard let item = o["item"] as? [String: Any] else { return [] }
        let started = o["type"] as? String == "item.started", done = o["type"] as? String == "item.completed"
        switch item["type"] as? String {
        case "command_execution":
            if started { return [WorkStep(kind: .tool, title: "Shell", text: WorkStep.clip(item["command"] as? String ?? "", 4000))] }
            if done {
                let out = item["aggregated_output"] as? String ?? ""
                let code = item["exit_code"] as? Int
                return [WorkStep(kind: .output, text: WorkStep.clip(out.isEmpty ? "(no output)" : out), failed: (code ?? 0) != 0 ? true : nil)]
            }
        case "file_change" where done:
            let changes = (item["changes"] as? [[String: Any]] ?? []).map { "\($0["kind"] as? String ?? "edit") \($0["path"] as? String ?? "")" }
            return [WorkStep(kind: .tool, title: "Edit", text: changes.joined(separator: "\n"))]
        case "reasoning" where done:
            if let t = item["text"] as? String, !t.isEmpty { return [WorkStep(kind: .thinking, text: WorkStep.clip(t))] }
        case "agent_message" where done:
            if let t = item["text"] as? String, !t.isEmpty { return [WorkStep(kind: .note, text: WorkStep.clip(t))] }
        case "web_search" where done:
            return [WorkStep(kind: .tool, title: "Web search", text: item["query"] as? String ?? "")]
        case "mcp_tool_call" where started:
            let args = (item["arguments"]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .prettyPrinted]) }
            return [WorkStep(kind: .tool, title: "\(item["server"] as? String ?? "mcp") \(item["tool"] as? String ?? "")",
                             text: WorkStep.clip(args.map { String(decoding: $0, as: UTF8.self) } ?? "", 4000))]
        case "todo_list" where started || o["type"] as? String == "item.updated":
            let list = (item["items"] as? [[String: Any]] ?? []).map { "\($0["completed"] as? Bool == true ? "[x]" : "[ ]") \($0["text"] as? String ?? "")" }
            return [WorkStep(kind: .tool, title: "Plan", text: list.joined(separator: "\n"))]
        default: break
        }
        return []
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

/// Collects streamed bytes and hands over each complete line as it arrives.
private final class LineFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    private let onLine: (Data) -> Void
    init(_ onLine: @escaping (Data) -> Void) { self.onLine = onLine }
    func append(_ d: Data) {
        lock.lock()
        buf.append(d)
        var lines: [Data] = []
        while let nl = buf.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buf[buf.startIndex..<nl])
            buf.removeSubrange(buf.startIndex...nl)
        }
        lock.unlock()
        for l in lines where !l.isEmpty { onLine(Data(l)) }
    }
}
