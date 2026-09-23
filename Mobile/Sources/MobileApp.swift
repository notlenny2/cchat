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
            .fontDesign(.rounded)
            .tint(Clay.terracotta)
            .onOpenURL { _ = client.pair(with: $0) }
            .onChange(of: phase) { _, p in
                if p == .active { client.start() } else if p == .background { client.stop() }
            }
            .onAppear { client.start() }
        }
    }
}

enum Palette {
    static let blue = Clay.terracotta
    static let gradients: [[Color]] = Clay.tones
}

struct Avatar: View {
    @EnvironmentObject var client: RemoteClient
    let contact: RemoteContact?
    var size: CGFloat = 44

    var body: some View {
        let g = Palette.gradients[abs(contact?.colorIndex ?? 0) % Palette.gradients.count]
        // Small avatars of a sub-contact wearing its project's icon (group pictures, group chat bubbles) all
        // looked identical and the initials badge was too tiny to read, so those show their own clay initials.
        let borrowed = contact.map { $0.parentId != nil && $0.ownIcon != true } ?? false
        let icon = borrowed && size < 32 ? nil : contact.flatMap { client.icons[$0.id] }
        ZStack {
            if let icon {
                Image(uiImage: icon).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
                    .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
                    .shadow(color: Clay.shadow.opacity(0.22), radius: 4, y: 3)
            } else {
                ClaySurface(shape: Circle(), color: g[1], depth: 0.8)
                    .overlay(Circle().fill(LinearGradient(colors: [g[0].opacity(0.9), .clear], startPoint: .top, endPoint: .center)))
                Text(contact?.initials ?? "…").font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                if contact?.parentId != nil {
                    // Small ring marks a sub-contact so it reads as "part of" a project.
                    Circle().strokeBorder(.white.opacity(0.55), lineWidth: max(1, size * 0.04)).padding(size * 0.06)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if icon != nil, let c = contact, c.parentId != nil, c.ownIcon != true, size >= 28 {
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
    var dot: CGFloat = 8
    var body: some View { ClayTypingDots(dot: dot) }
}

func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    return d.formatted(date: .numeric, time: .omitted)
}
