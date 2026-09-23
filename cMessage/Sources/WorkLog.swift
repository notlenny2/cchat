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
            .frame(maxHeight: (live ? 240 : 380) * zoom)
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

    @ViewBuilder private func row(_ s: WorkStep) -> some View {
        switch s.kind {
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(s.title).font(mono.weight(.bold)).foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.42))
                Text(s.title == "Bash" || s.title == "Shell" ? "$ \(s.text)" : s.text)
                    .font(mono).foregroundStyle(.white.opacity(0.92))
            }
            .padding(.top, 3)
        case .output:
            Text(s.text).font(mono).lineLimit(live ? 8 : 40)
                .foregroundStyle(s.failed == true ? Color(red: 1, green: 0.5, blue: 0.45) : .white.opacity(0.55))
                .padding(.leading, 12)
        case .note:
            Text(s.text).font(.system(size: 12 * zoom, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                .padding(.top, 3)
        case .thinking:
            Text(s.text).font(.system(size: 11.5 * zoom, design: .rounded).italic()).lineLimit(live ? 6 : 30)
                .foregroundStyle(.white.opacity(0.45))
        }
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
