import SwiftUI

/// How much of a plan's limit is used up, as the AI company itself reports it.
struct UsageWindow: Codable, Hashable {
    /// 0...1
    var used: Double
    var resetsAt: Date?

    /// Past the reset time the limit has refilled, even if nobody has asked since.
    var current: Double { (resetsAt.map { $0 < Date() } ?? false) ? 0 : used }
}

struct PlanUsage: Codable, Hashable {
    /// The short rolling limit (5 hours for both Claude and Codex).
    var session: UsageWindow?
    /// The weekly limit.
    var week: UsageWindow?
    var asOf: Date
}

struct UsageReport: Codable, Hashable {
    var claude: PlanUsage?
    var codex: PlanUsage?
    var isEmpty: Bool { claude == nil && codex == nil }
}

/// The meter at the bottom of the chat list (Mac and iPhone/iPad): one line per AI, two clay bars each.
struct UsageMeter: View {
    var report: UsageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = report.claude { row("Claude", c) }
            if let c = report.codex { row("Codex", c) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .clay(Clay.cream, radius: 14, depth: 0.6)
    }

    private func row(_ name: String, _ u: PlanUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(.caption, design: .rounded).weight(.semibold)).foregroundStyle(Clay.ink)
            if let s = u.session { bar("Next few hours", s) }
            if let w = u.week { bar("This week", w) }
        }
        .help("As of \(u.asOf.formatted(.relative(presentation: .named)))")
    }

    private func bar(_ label: String, _ w: UsageWindow) -> some View {
        let v = min(max(w.current, 0), 1)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int((v * 100).rounded()))%").monospacedDigit()
            }
            .font(.system(.caption2, design: .rounded)).foregroundStyle(Clay.ink.opacity(0.7))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Clay.ink.opacity(0.1))
                    Capsule().fill(color(v)).frame(width: max(4, g.size.width * v))
                }
            }
            .frame(height: 5)
            if let r = w.resetsAt, r > Date(), v >= 0.5 {
                Text("Refills \(Self.when(r))").font(.system(.caption2, design: .rounded)).foregroundStyle(Clay.ink.opacity(0.55))
            }
        }
    }

    private func color(_ v: Double) -> Color { v >= 0.9 ? .red : v >= 0.7 ? .orange : Clay.terracotta }

    static func when(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "at \(d.formatted(date: .omitted, time: .shortened))"
            : d.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}
