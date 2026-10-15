import Foundation

/// A text the user wrote now but wants sent later: at a set time, or when a usage limit refills.
/// Lives on its chat (`Conversation.scheduled`) so it survives a restart; if cChat was closed when it was
/// due, it goes out as soon as cChat is open again.
struct ScheduledSend: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var attachments: [String]? = nil
    var at: Date
    /// Shown with it, e.g. "when your Claude limit resets". nil = just the time.
    var why: String? = nil
    /// Another agent scheduled it for the user (same rule as `Message.from`).
    var from: String? = nil
}

/// The choices in "Send Later", worked out from the usage meter so "when my limit resets" means a real time.
enum SendLater {
    struct Choice: Identifiable, Hashable {
        var id: String { label }
        let label: String
        let at: Date
        let why: String?
    }

    /// A minute after the reset, so the limit really has refilled by the time the agent starts.
    static let afterReset: TimeInterval = 60

    static func choices(usage: UsageReport, engine: Engine?, now: Date = Date()) -> [Choice] {
        var out: [Choice] = []
        // Limits only exist for engines that report them (Claude, Codex); the chat's own engine first.
        let plans: [(String, PlanUsage?)] = engine == .codex
            ? [("Codex", usage.codex), ("Claude", usage.claude)]
            : [("Claude", usage.claude), ("Codex", usage.codex)]
        for (name, plan) in plans {
            if let r = plan?.session?.resetsAt, r > now {
                out.append(Choice(label: "When my \(name) limit resets · \(when(r, now))", at: r + afterReset,
                                  why: "when your \(name) limit resets"))
            }
            if let r = plan?.week?.resetsAt, r > now, r.timeIntervalSince(now) > 6 * 3600 {
                out.append(Choice(label: "When my \(name) weekly limit resets · \(when(r, now))", at: r + afterReset,
                                  why: "when your weekly \(name) limit resets"))
            }
        }
        let cal = Calendar.current
        out.append(Choice(label: "In 1 hour", at: now + 3600, why: nil))
        out.append(Choice(label: "In 3 hours", at: now + 3 * 3600, why: nil))
        if let tonight = cal.date(bySettingHour: 21, minute: 0, second: 0, of: now), tonight > now + 1800 {
            out.append(Choice(label: "Tonight at 9 PM", at: tonight, why: nil))
        }
        if let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!) {
            out.append(Choice(label: "Tomorrow at 8 AM", at: morning, why: nil))
        }
        return out
    }

    /// "3:42 PM", "tomorrow 9:00 AM", "Tue 9:00 AM".
    static func when(_ d: Date, _ now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDate(d, inSameDayAs: now) { return time }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "tomorrow \(time)" }
        if d.timeIntervalSince(now) < 6 * 86400 { return d.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The line under the text box for one waiting message.
    static func caption(_ s: ScheduledSend) -> String {
        "Sends \(when(s.at))" + (s.why.map { ", \($0)" } ?? "")
    }
}
