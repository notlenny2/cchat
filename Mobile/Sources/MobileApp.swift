import SwiftUI

@main
struct CMessageMobileApp: App {
    @StateObject private var client = RemoteClient()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if client.pairing == nil {
                    PairView()
                } else {
                    MainView()
                }
            }
            .environmentObject(client)
            .onOpenURL { _ = client.pair(with: $0) }
            .onChange(of: phase) { _, p in
                if p == .active { client.start() } else if p == .background { client.stop() }
            }
            .onAppear { client.start() }
        }
    }
}

enum Palette {
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let gradients: [[Color]] = [
        [Color(red: 0.55, green: 0.60, blue: 0.68), Color(red: 0.40, green: 0.44, blue: 0.52)],
        [Color(red: 0.99, green: 0.62, blue: 0.35), Color(red: 0.96, green: 0.40, blue: 0.24)],
        [Color(red: 0.42, green: 0.78, blue: 0.98), Color(red: 0.16, green: 0.52, blue: 0.94)],
        [Color(red: 0.55, green: 0.88, blue: 0.50), Color(red: 0.20, green: 0.66, blue: 0.36)],
        [Color(red: 0.84, green: 0.56, blue: 0.98), Color(red: 0.58, green: 0.30, blue: 0.90)],
        [Color(red: 1.00, green: 0.55, blue: 0.66), Color(red: 0.92, green: 0.26, blue: 0.44)],
        [Color(red: 0.99, green: 0.84, blue: 0.36), Color(red: 0.95, green: 0.62, blue: 0.14)],
        [Color(red: 0.40, green: 0.88, blue: 0.84), Color(red: 0.10, green: 0.62, blue: 0.64)],
    ]
}

struct Avatar: View {
    @EnvironmentObject var client: RemoteClient
    let contact: RemoteContact?
    var size: CGFloat = 44

    var body: some View {
        let g = Palette.gradients[abs(contact?.colorIndex ?? 0) % Palette.gradients.count]
        let icon = contact.flatMap { client.icons[$0.id] }
        ZStack {
            if let icon {
                Image(uiImage: icon).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
            } else {
                Circle().fill(LinearGradient(colors: g, startPoint: .top, endPoint: .bottom))
                Text(contact?.initials ?? "…").font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if icon != nil, let c = contact, c.parentId != nil, size >= 28 {
                Text(c.initials).font(.system(size: max(7, size * 0.2), weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, size * 0.07).padding(.vertical, size * 0.03)
                    .background(Capsule().fill(LinearGradient(colors: g, startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                    .offset(x: size * 0.08, y: size * 0.04)
            }
        }
    }
}

struct GroupAvatar: View {
    @EnvironmentObject var client: RemoteClient
    let ids: [UUID]
    var size: CGFloat = 44

    var body: some View {
        if ids.count <= 1 {
            Avatar(contact: client.contact(ids.first), size: size)
        } else {
            ZStack {
                Avatar(contact: client.contact(ids[0]), size: size * 0.66).offset(x: -size * 0.17, y: -size * 0.17)
                Avatar(contact: client.contact(ids[1]), size: size * 0.66)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                    .offset(x: size * 0.17, y: size * 0.17)
            }
            .frame(width: size, height: size)
        }
    }
}

struct TypingDots: View {
    var dot: CGFloat = 7
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * 5
            HStack(spacing: dot * 0.55) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary).frame(width: dot, height: dot)
                        .opacity(0.3 + 0.7 * max(0, sin(t - Double(i) * 0.9)))
                }
            }
        }
    }
}

func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    return d.formatted(date: .numeric, time: .omitted)
}
