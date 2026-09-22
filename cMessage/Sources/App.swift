import SwiftUI
import AppKit

/// macOS restores the window wherever it was last, which on the user's desk can be an AirPlay screen
/// ("Studio") or a monitor that isn't there any more. At launch, always open on the primary display
/// (the one with the menu bar); later, only step in if the window ends up on no screen at all.
enum WindowRescue {
    static func run(atLaunch: Bool = false) {
        guard let primary = NSScreen.screens.first else { return }
        for w in NSApp.windows where w.isVisible && w.styleMask.contains(.titled) {
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(w.frame) }
            let onPrimary = primary.visibleFrame.intersects(w.frame)
            guard atLaunch ? !onPrimary : !onScreen else { continue }
            Log.info("window at \(w.frame) moved to primary display")
            let v = primary.visibleFrame
            let size = NSSize(width: min(max(w.frame.width, 1000), v.width), height: min(max(w.frame.height, 680), v.height))
            w.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
    }
}

@main
struct CMessageApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("cChat") {
            ContentView()
                .environmentObject(store)
                .fontDesign(.rounded)
                .tint(Clay.terracotta)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear {
                    Log.info("launch, claude=\(ClaudeRunner.claudePath ?? "MISSING")")
                    DispatchQueue.main.async { WindowRescue.run(atLaunch: true) }
                    RemoteServer.shared.attach(store)
                    SelfUpdate.start(store)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                    WindowRescue.run()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { NotificationCenter.default.post(name: .newMessage, object: nil) }
                    .keyboardShortcut("n")
                Button("Contacts") { NotificationCenter.default.post(name: .showContacts, object: nil) }
                    .keyboardShortcut("k")
                Divider()
                Button("Connect iPhone or iPad…") { NotificationCenter.default.post(name: .showPairing, object: nil) }
            }
        }
    }
}

extension Notification.Name {
    static let newMessage = Notification.Name("cmessage.newMessage")
    static let showContacts = Notification.Name("cmessage.showContacts")
    static let renameChat = Notification.Name("cmessage.renameChat")
    static let showPairing = Notification.Name("cmessage.showPairing")
}

// MARK: - Look

enum Palette {
    static let blue = Clay.terracotta   // the app's accent; kept under its old name
    static let gradients: [[Color]] = Clay.tones
}

struct Avatar: View {
    @EnvironmentObject var store: Store
    let contact: Contact?
    var size: CGFloat = 40

    var body: some View {
        let g = Palette.gradients[abs(contact?.colorIndex ?? 0) % Palette.gradients.count]
        let icon = contact.flatMap { IconCache.image(store.iconPath(for: $0)) }
        ZStack {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFill()
                    .frame(width: size, height: size).clipShape(Circle())
                    .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
                    .shadow(color: Clay.shadow.opacity(0.22), radius: 4, y: 3)
            } else {
                ClaySurface(shape: Circle(), color: g[1], depth: 0.8)
                    .overlay(Circle().fill(LinearGradient(colors: [g[0].opacity(0.9), .clear], startPoint: .top, endPoint: .center)))
                Text(contact?.initials ?? "?")
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                if contact?.isSubContact == true {
                    // Small ring marks a sub-contact so it reads as "part of" a project.
                    Circle().strokeBorder(.white.opacity(0.55), lineWidth: max(1, size * 0.04)).padding(size * 0.06)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            // A sub-contact wearing its project's icon gets a little initials badge so you can tell them apart.
            if icon != nil, let c = contact, c.isSubContact, c.iconPath == nil, size >= 26 {
                Text(c.initials)
                    .font(.system(size: max(7, size * 0.2), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, size * 0.07).padding(.vertical, size * 0.03)
                    .background(Capsule().fill(LinearGradient(colors: g, startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: size * 0.08, y: size * 0.04)
            }
        }
    }
}

/// Small tag next to a chat's name when Codex (not Claude) is answering.
struct EngineBadge: View {
    let conv: Conversation
    var body: some View {
        if conv.usesCodex {
            Text("Codex").font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .foregroundStyle(.white)
                .background(Capsule().fill(Color(red: 0.13, green: 0.13, blue: 0.15)))
        }
    }
}

struct GroupAvatar: View {
    @EnvironmentObject var store: Store
    let ids: [UUID]
    var size: CGFloat = 40
    var photo: String? = nil

    var body: some View {
        if let img = IconCache.image(photo) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
        } else if ids.count <= 1 {
            Avatar(contact: store.contact(ids.first), size: size)
        } else {
            ZStack {
                Avatar(contact: store.contact(ids[0]), size: size * 0.66).offset(x: -size * 0.17, y: -size * 0.17)
                Avatar(contact: store.contact(ids[1]), size: size * 0.66)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(x: size * 0.17, y: size * 0.17)
            }
            .frame(width: size, height: size)
        }
    }
}
