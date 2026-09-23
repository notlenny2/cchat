import SwiftUI
import AppKit
import SwiftTerm

/// A real terminal that slides up over the bottom of the chat (toolbar button or ⌃`), already sitting in
/// the open chat's project folder. One shell per folder, kept alive while hidden, so switching chats and
/// back finds the same shell where you left it.
@MainActor
final class TerminalPool: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalPool()
    @Published var shown = false
    @Published var height: CGFloat = 260
    private var shells: [String: LocalProcessTerminalView] = [:]

    func toggle() { withAnimation(.snappy) { shown.toggle() } }

    func terminal(for folder: String) -> LocalProcessTerminalView {
        if let t = shells[folder] { return t }
        let t = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        t.processDelegate = self
        t.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        t.nativeBackgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        t.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        t.caretColor = NSColor(Clay.terracotta)
        start(t, in: folder)
        shells[folder] = t
        return t
    }

    private func start(_ t: LocalProcessTerminalView, in folder: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env += ["HOME=\(home)", "PATH=\(ClaudeRunner.loginPath)", "USER=\(NSUserName())", "SHELL=\(shell)"]
        let dir = FileManager.default.fileExists(atPath: folder) ? folder : home
        t.startProcess(executable: shell, args: ["-l"], environment: env,
                       execName: "-" + URL(fileURLWithPath: shell).lastPathComponent, currentDirectory: dir)
    }

    // The shell ended (typed `exit`): forget it, so the next time the drawer opens there's a fresh one.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            if let key = self.shells.first(where: { $0.value === source })?.key {
                self.shells[key]?.removeFromSuperview()
                self.shells.removeValue(forKey: key)
                withAnimation(.snappy) { self.shown = false }
            }
        }
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// A row just above the text box. Folded it's one slim "Terminal" line; tap it (or ⌃`) and the terminal
/// opens right there. Drag the top edge to make it taller or shorter.
struct TerminalDrawer: View {
    @ObservedObject var pool = TerminalPool.shared
    let folder: String
    @State private var dragStart: CGFloat?

    private static let dark = Color(red: 0.11, green: 0.12, blue: 0.14)

    var body: some View {
        VStack(spacing: 0) {
            Button { pool.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "terminal").font(.caption)
                    Text("Terminal").font(.system(.caption, design: .rounded).weight(.semibold))
                    Text(URL(fileURLWithPath: folder).lastPathComponent).font(.system(.caption, design: .rounded))
                        .opacity(0.7).lineLimit(1)
                    Spacer()
                    Image(systemName: pool.shown ? "chevron.down" : "chevron.up").font(.caption.weight(.semibold))
                }
                .foregroundStyle(pool.shown ? Color(white: 0.8) : Clay.inkSoft)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pool.shown ? "Fold the terminal away (⌃`)" : "Open a terminal in this project's folder (⌃`)")
            .overlay(alignment: .top) {
                if pool.shown {
                    // Grab strip along the top edge for resizing.
                    Color.clear.frame(height: 6).contentShape(Rectangle())
                        .overlay(Capsule().fill(Color(white: 0.5)).frame(width: 36, height: 4).padding(.top, 2), alignment: .top)
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                if dragStart == nil { dragStart = pool.height }
                                pool.height = min(max((dragStart ?? pool.height) - v.translation.height, 120), 700)
                            }
                            .onEnded { _ in dragStart = nil })
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                }
            }
            if pool.shown {
                TerminalHost(folder: folder).padding(.horizontal, 6).padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(height: pool.shown ? pool.height : nil)
        .background(pool.shown ? Self.dark : Clay.sidebar.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(pool.shown ? 0.25 : 0), radius: 10, y: -2)
        .padding(.horizontal, 14)
    }
}

private struct TerminalHost: NSViewRepresentable {
    let folder: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ box: NSView, context: Context) {
        let t = TerminalPool.shared.terminal(for: folder)
        guard t.superview !== box else { return }
        box.subviews.forEach { $0.removeFromSuperview() }
        t.removeFromSuperview()
        t.frame = box.bounds
        t.autoresizingMask = [.width, .height]
        box.addSubview(t)
        DispatchQueue.main.async { t.window?.makeFirstResponder(t) }
    }
}
