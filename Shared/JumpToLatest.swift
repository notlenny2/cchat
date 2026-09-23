import SwiftUI

/// The round "jump to the newest message" button that floats over a chat once you've scrolled up.
/// The transcript reports where its bottom marker sits (`reportsChatBottom`) and how tall the visible area is
/// (`chatViewport`); when the marker is more than a screenful-ish below the view, the button shows.
enum ChatScroll {
    static let space = "chatScroll"
    /// How far past the bottom edge (points) the end can be before it counts as "scrolled up".
    static let slack: CGFloat = 120
}

struct ChatBottomY: PreferenceKey {
    /// Not reported = the end isn't laid out at all (a lazy list far from it), so treat it as far away.
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

extension View {
    /// Put on the transcript's bottom marker.
    func reportsChatBottom() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: ChatBottomY.self, value: g.frame(in: .named(ChatScroll.space)).maxY)
        })
    }

    /// Put on the ScrollView: tracks whether the newest message is out of sight and overlays the button.
    func jumpToLatest(_ scrolledUp: Binding<Bool>, action: @escaping () -> Void) -> some View {
        GeometryReader { outer in
            coordinateSpace(name: ChatScroll.space)
                .onPreferenceChange(ChatBottomY.self) { y in
                    let up = y > outer.size.height + ChatScroll.slack
                    if up != scrolledUp.wrappedValue { scrolledUp.wrappedValue = up }
                }
        }
            .overlay(alignment: .bottomTrailing) {
                if scrolledUp.wrappedValue {
                    JumpToLatestButton(action: action)
                        .padding(14)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: scrolledUp.wrappedValue)
    }
}

struct JumpToLatestButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Clay.terracotta)
                .frame(width: 38, height: 38)
                .clay(Clay.cream, radius: 19)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Jump to the latest message")
        .accessibilityLabel("Jump to the latest message")
    }
}
