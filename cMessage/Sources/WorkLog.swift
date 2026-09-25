import SwiftUI

/// View > Show the Work: what an agent actually did for a reply (files it read, commands it ran and what they
/// printed, its thinking), laid out like a terminal. Off by default; the chat stays plain English until you ask.
enum ShowWork {
    static let key = "showWork"
    static func toggle() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key) }
}

struct WorkLog: View {
    let steps: [WorkStep]
    /// Live = the turn is still running: follow the newest line.
    var live = false
    @Environment(\.zoom) private var zoom

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(steps) { step in row(step).id(step.id) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: (live ? 280 : 520) * zoom)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { if live, let last = steps.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: steps.count) { _, _ in
                if live, let last = steps.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .textSelection(.enabled)
    }

    private var mono: Font { .system(size: 11 * zoom, design: .monospaced) }

    private static let red = Color(red: 1, green: 0.5, blue: 0.45), green = Color(red: 0.55, green: 0.85, blue: 0.55)

    @ViewBuilder private func row(_ s: WorkStep) -> some View {
        Group {
            switch s.kind {
            case .tool:
                let lines = s.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.title).font(mono.weight(.bold)).foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.42))
                        Text((s.title == "Bash" || s.title == "Shell" ? "$ " : "") + String(lines.first ?? ""))
                            .font(mono).foregroundStyle(.white.opacity(0.92))
                    }
                    if lines.count > 1 { detail(String(lines[1])) }
                }
                .padding(.top, 3)
            case .output:
                Text(s.text).font(mono).lineLimit(live ? 12 : nil)
                    .foregroundStyle(s.failed == true ? Self.red : .white.opacity(0.55))
                    .padding(.leading, 12)
            case .note:
                Text(s.text).font(.system(size: 12 * zoom, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 3)
            case .thinking:
                Text(s.text).font(.system(size: 11.5 * zoom, design: .rounded).italic()).lineLimit(live ? 8 : nil)
                    .foregroundStyle(.white.opacity(0.45))
            case .info:
                Text(s.text).font(.system(size: 10.5 * zoom, design: .monospaced)).lineLimit(live ? 3 : 12)
                    .foregroundStyle(s.failed == true ? Self.red : .white.opacity(0.38))
                    .padding(.vertical, 2)
            }
        }
        // A helper agent's steps sit under the call that sent it, behind a thin rule.
        .padding(.leading, s.sub == true ? 12 : 0)
        .overlay(alignment: .leading) {
            if s.sub == true { Rectangle().fill(.white.opacity(0.15)).frame(width: 1.5).padding(.leading, 3) }
        }
    }

    /// The rest of a tool call: an edit's before/after in red and green, a command's description, a helper's orders.
    private func detail(_ text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(live ? 14 : 400)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l.isEmpty ? " " : String(l)).font(mono)
                    .foregroundStyle(l.hasPrefix("- ") || l == "-" ? Self.red : l.hasPrefix("+ ") || l == "+" ? Self.green
                                     : l.hasPrefix("#") ? .white.opacity(0.4) : .white.opacity(0.7))
            }
        }
        .padding(.leading, 12)
    }
}

/// Under an agent's reply: "Show the work (12 steps)", folded until clicked.
struct WorkDisclosure: View {
    let steps: [WorkStep]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    Text(summary).zfont(.caption2, weight: .medium)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if open { WorkLog(steps: steps) }
        }
    }

    private var summary: String {
        let tools = steps.filter { $0.kind == .tool }.count
        return tools == 0 ? "How it got here" : "The work: \(tools) step\(tools == 1 ? "" : "s")"
    }
}
