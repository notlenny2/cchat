import SwiftUI
import AppKit

/// Settings > This Mac: is this the Mac the agents run on (the server), or a workstation that shows the server's
/// chats? Plus the link that joins a workstation to its server.
struct MacRoleRow: View {
    @ObservedObject private var server = RemoteServer.shared
    @State private var wantWorkstation = Prefs.isWorkstation
    @State private var pasted = ""
    @State private var linkError: String?
    @State private var copied = false

    private let workstationNow = Prefs.isWorkstation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $wantWorkstation) {
                Text("Server: agents run on this Mac").tag(false)
                Text("Workstation: use another Mac's chats").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if wantWorkstation != workstationNow {
                HStack {
                    Button(wantWorkstation ? "Switch to Workstation and Restart" : "Switch to Server and Restart", action: switchRole)
                        .buttonStyle(.borderedProminent)
                        .disabled(Self.busyHere)
                    if Self.busyHere { Text("Wait for the replies being written to finish.").font(.caption).foregroundStyle(Clay.inkSoft) }
                }
                Text(wantWorkstation
                     ? "This Mac's own chats stay saved here, untouched, and come back if you switch it back to a server."
                     : "This Mac's own chats come back and its agents run here again.")
                    .font(.caption).foregroundStyle(Clay.inkSoft)
            } else if workstationNow {
                workstationLink
            } else {
                serverLink
            }
        }
    }

    /// On the server: the link a workstation pastes in. It's the same secret the phone's QR code holds.
    @ViewBuilder private var serverLink: some View {
        if let p = server.pairing {
            Text("To use these chats on another Mac, set that Mac to Workstation and paste this link into it:")
                .font(.caption).foregroundStyle(Clay.inkSoft)
            HStack {
                Text(p.url.absoluteString).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.url.absoluteString, forType: .string)
                    copied = true
                }
            }
            Text("Your Macs share a clipboard, so copy it here and paste it there. Treat it like a password: anyone with it can use your chats. Making a new phone code below makes a new link too.")
                .font(.caption).foregroundStyle(Clay.inkSoft)
        } else {
            Text("Turn on linking under iPhone and iPad below first; the same link lets another Mac in.")
                .font(.caption).foregroundStyle(Clay.inkSoft)
        }
    }

    /// On a workstation: which server it's linked to, how that's going, and where to paste a new link.
    @ViewBuilder private var workstationLink: some View {
        if let link = ServerLink.shared {
            WorkstationStatus(link: link)
            HStack {
                TextField(link.pairing == nil ? "Paste the link from your server Mac" : "Paste a new link to change servers", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                Button("Link") {
                    if link.link(pasted) { pasted = ""; linkError = nil }
                    else { linkError = "That isn't a cChat link. On the server Mac, open Settings > This Mac and copy it again." }
                }
                .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let linkError { Text(linkError).font(.caption).foregroundStyle(.red) }
            if link.pairing != nil { Button("Unlink This Mac") { link.unlink() }.buttonStyle(.link).font(.caption) }
        }
    }

    private static var busyHere: Bool {
        !Prefs.isWorkstation && NSApp.windows.isEmpty == false && Store.anyBusy
    }

    private func switchRole() {
        Prefs.isWorkstation = wantWorkstation
        Log.info("switching this Mac to \(wantWorkstation ? "workstation" : "server")")
        let path = Bundle.main.bundlePath
        // Reopen once this copy has gone (a fresh launch reads the new role).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done; open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// "Linked to Studio Mac, connected" (or why it isn't).
struct WorkstationStatus: View {
    @ObservedObject var link: ServerLink
    var body: some View {
        switch link.state {
        case .unlinked:
            Label("Not linked to a server Mac yet", systemImage: "link.badge.plus").foregroundStyle(Clay.inkSoft)
        case .connecting:
            Label("Connecting to \(link.serverName)…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Clay.inkSoft)
        case .online:
            Label("Using \(link.serverName)'s chats" + (link.viaRelay ? " (away from home)" : ""), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .offline(let why):
            Label(why, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
        }
    }
}

/// Under the chat list on a workstation, only while the server can't be reached.
struct WorkstationBanner: View {
    @ObservedObject var link: ServerLink
    var body: some View {
        if link.state != .online {
            WorkstationStatus(link: link).font(.caption).padding(.horizontal, 12).padding(.top, 8)
        }
    }
}

/// A workstation's main window before it has anything to show: link it, or wait for the server.
struct WorkstationEmpty: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "desktopcomputer.and.arrow.down").font(.system(size: 40)).foregroundStyle(Clay.terracotta)
            Text("This Mac is a workstation").font(.title2.bold()).foregroundStyle(Clay.ink)
            if let link = store.link { WorkstationStatus(link: link) }
            Text(store.link?.pairing == nil
                 ? "It shows the chats on your server Mac. On that Mac open Settings > This Mac, copy the link, then paste it here in Settings > This Mac."
                 : "Your chats will show up here once it connects.")
                .multilineTextAlignment(.center).foregroundStyle(Clay.inkSoft).frame(maxWidth: 380)
            SettingsLink { Text("Open Settings") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Clay.canvas.ignoresSafeArea())
    }
}
