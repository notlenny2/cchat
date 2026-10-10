import Foundation

/// "Smart" model choice: before a Claude turn, one quick Haiku call (no tools, no memory, a fraction of a cent)
/// reads the message and picks which model answers and how hard it thinks. Small asks go to a quick, cheap model;
/// real building and debugging go to a stronger one.
enum SmartModel {
    struct Pick: Equatable {
        var model: String   // haiku | sonnet | opus | fable
        var effort: String  // low | medium | high | xhigh | max
        var why: String

        var label: String {
            let m = ModelCatalog.label(model, in: ModelCatalog.claude) ?? model
            let e = (ModelCatalog.label(effort, in: ModelCatalog.efforts) ?? effort).lowercased()
            return "\(m) · \(e) thinking"
        }
    }

    static let models = ["haiku", "sonnet", "opus", "fable"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    /// Used when the quick call fails: the same thing "Default" would run.
    static let fallback = Pick(model: ModelCatalog.claudeDefault, effort: "medium", why: "couldn't decide, so the usual")

    static let system = """
    You route messages for a coding assistant. Pick the cheapest model and thinking level that will do the job well.
    Models, weakest to strongest: haiku (chit-chat, yes/no, a quick look-up, a one-line change), sonnet (everyday
    coding, small features, ordinary bugs, explaining), opus (real features, tricky bugs, multi-file changes, design
    decisions), fable (the hardest: big architecture, deep debugging after other attempts failed, risky migrations).
    Thinking: low (obvious), medium (normal), high (needs care), xhigh (hard, many steps), max (very hard, rarely).
    Planning-only messages still need a strong model if the plan is for something big.
    Reply with JSON only: {"model":"...","effort":"...","why":"a few plain words"}
    """

    /// `memory` = tokens the chat's session already holds (Haiku's window is smaller, so a big session can't go to it).
    /// `last` = the model the previous turn ran; switching models starts its memory cache over, so only switch for a reason.
    static func pick(message: String, recent: String, memory: Int?, last: String?, planning: Bool) async -> Pick {
        var p = "Message:\n\(message.prefix(3000))"
        if !recent.isEmpty { p += "\n\nWhat came just before (for context):\n\(recent.prefix(1500))" }
        if planning { p += "\n\nThe assistant will only plan this, not do it yet." }
        if let last { p += "\n\nThe last reply used \(last). Prefer staying on it unless this message clearly needs more or less." }
        guard let out = try? await ClaudeRunner.quick(prompt: p, system: system) else {
            Log.error("smart pick failed, using default")
            return fallback
        }
        var pick = parse(out) ?? fallback
        // Haiku can't hold a big chat's memory (and a resume would fail), so step up.
        if pick.model == "haiku", (memory ?? 0) > 120_000 { pick.model = "sonnet"; pick.why += " (chat too long for Haiku)" }
        Log.info("smart pick \(pick.model)/\(pick.effort): \(pick.why)")
        return pick
    }

    static func parse(_ text: String) -> Pick? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
              let o = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any],
              let m = (o["model"] as? String)?.lowercased(), models.contains(m) else { return nil }
        let e = (o["effort"] as? String)?.lowercased() ?? "medium"
        let why = (o["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Pick(model: m, effort: efforts.contains(e) ? e : "medium", why: String(why.prefix(120)))
    }
}
