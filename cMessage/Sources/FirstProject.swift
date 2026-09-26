import SwiftUI
import AppKit

/// The first thing a brand-new user sees: one card, one text box, one button.
/// Names the project, makes its folder, and opens its chat, so the first text happens within a minute.
struct FirstProjectCard: View {
    @EnvironmentObject var store: Store
    /// Called after a project exists and its chat is open (sheets use it to close themselves).
    var done: () -> Void = {}
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private static let ideas = ["Sourdough Site", "Trail Buddy", "Home Budget", "Recipe Box", "Wedding Planner", "Band Merch"]
    private let idea = ideas.randomElement() ?? "Sourdough Site"

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) { ClayDimple(size: 12); ClayDimple(size: 12); ClayDimple(size: 12) }
                .padding(.horizontal, 26).padding(.vertical, 20)
                .clay(Clay.terracotta, radius: 26)
            VStack(spacing: 6) {
                Text("Start your first project").font(.title2.bold())
                Text("Give it a name. cChat makes a folder for it and opens a chat.\nThen just text it what you want built.")
                    .foregroundStyle(Clay.inkSoft).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                TextField("Something like \(idea)", text: $name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .clay(Clay.cream, radius: 14, depth: 0.5)
                    .focused($focused)
                    .onSubmit(start)
                Button(action: start) {
                    Text("Start").font(.body.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .clayCapsule(ready ? Clay.terracotta : Clay.inkSoft.opacity(0.45), depth: ready ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 360)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            Button("Already have a folder? Pick it instead", action: pickFolder)
                .buttonStyle(.plain).font(.callout).foregroundStyle(Clay.inkSoft).underline()
        }
        .padding(28)
        .frame(maxWidth: 440)
        .onAppear { focused = true }
    }

    private var ready: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private func start() {
        guard ready else { return }
        do {
            let c = try store.createProject(named: name)
            open(c)
            name = ""; error = nil
            done()
        } catch { self.error = error.localizedDescription }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.fileExists(atPath: Prefs.projectsRoot.path)
            ? Prefs.projectsRoot : FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Text This Folder"
        panel.message = "Pick a folder to text. Everything the agent builds goes in there."
        if panel.runModal() == .OK, let u = panel.url {
            open(store.addProject(path: u.path))
            done()
        }
    }

    /// Opens the project's chat; a brand-new, empty chat gets three starter chips so the first text is one tap.
    private func open(_ c: Contact) {
        store.openChat(with: c)
        if let id = store.selectedId, let i = store.index(of: id), store.conversations[i].messages.isEmpty,
           store.conversations[i].suggestions.isEmpty {
            store.conversations[i].suggestions = ["what can you help me with?", "build me a simple one-page website", "let's plan this out first"]
            store.save()
        }
    }
}
