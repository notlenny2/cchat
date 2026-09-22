import SwiftUI
import AppKit

// MARK: - Contacts book

struct ContactsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Contact?
    @State private var addingSubTo: Contact?
    @State private var expanded: Set<UUID> = []
    @State private var importNote: String?

    private var projectsRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects") }

    /// Folders in ~/projects that aren't contacts yet.
    private var unaddedFolders: [URL] {
        let taken = Set(store.projects.map(\.projectPath))
        let items = (try? FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !taken.contains($0.path) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Contacts").font(.title2.bold())
                Spacer()
                Menu {
                    ForEach(unaddedFolders, id: \.self) { u in
                        Button(u.lastPathComponent) { store.addProject(path: u.path) }
                    }
                    Divider()
                    Button("Choose Folder…", action: pickFolder)
                    if NodeTermImport.isInstalled {
                        Button("Import Chats from NodeTerm") {
                            let n = store.importNodeTerm()
                            importNote = n == 0 ? "Nothing new in NodeTerm." : "Brought over \(n) chat\(n == 1 ? "" : "s") from NodeTerm."
                        }
                    }
                } label: { Label("Add Project", systemImage: "plus") }
                .fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            if let importNote {
                Text(importNote).font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            Divider()
            if store.projects.isEmpty {
                VStack(spacing: 8) {
                    Text("No contacts yet").font(.headline)
                    Text("Every project is a contact. Add one from ~/projects with the + button, or bring over your NodeTerm chats.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                List {
                    ForEach(store.projects) { p in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(p.id) },
                            set: { if $0 { expanded.insert(p.id) } else { expanded.remove(p.id) } })) {
                            ForEach(store.subContacts(of: p.id)) { s in
                                row(s)
                            }
                            Button { addingSubTo = p } label: {
                                Label("New sub-contact", systemImage: "person.badge.plus")
                            }
                            .buttonStyle(.borderless).padding(.leading, 40)
                        } label: {
                            row(p)
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 560)
        .sheet(item: $editing) { c in ContactEditor(contact: c).environmentObject(store) }
        .sheet(item: $addingSubTo) { p in SubContactSheet(project: p).environmentObject(store) }
    }

    private func row(_ c: Contact) -> some View {
        HStack(spacing: 10) {
            Avatar(contact: c, size: c.isSubContact ? 30 : 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(c.isSubContact ? .body : .headline)
                Text(c.isSubContact ? (c.role.isEmpty ? "Sub-contact" : c.role) : URL(fileURLWithPath: c.projectPath).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { store.openChat(with: c); dismiss() } label: { Image(systemName: "message.fill") }
                .buttonStyle(.borderless).foregroundStyle(Palette.blue).help("Message")
            Button { editing = c } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).help("Info")
        }
        .padding(.vertical, 2)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = projectsRoot
        panel.prompt = "Add"
        if panel.runModal() == .OK { panel.urls.forEach { store.addProject(path: $0.path) } }
    }
}

// MARK: - New sub-contact

struct SubContactSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let project: Contact
    @State private var name = ""
    @State private var role = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Avatar(contact: project, size: 36)
                Text("New contact under \(project.name)").font(.headline)
            }
            HStack {
                Text("Quick pick:").foregroundStyle(.secondary)
                Menu("The Team") {
                    ForEach(TeamPreset.allCases) { t in
                        Button(t.name) { name = t.name; role = t.role }
                    }
                }
                .fixedSize()
            }
            TextField("Name (like UX, Director, Bug Hunter)", text: $name)
            VStack(alignment: .leading, spacing: 4) {
                Text("Who are they?").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $role)
                    .font(.body)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add and Message") {
                    let c = store.addSubContact(to: project, name: name.trimmingCharacters(in: .whitespaces), role: role)
                    store.openChat(with: c)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Contact info / editor

struct ContactEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var contact: Contact
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 14) {
            Avatar(contact: contact, size: 64)
            if let p = store.contact(contact.parentId) {
                Text("Part of \(p.name)").font(.caption).foregroundStyle(.secondary)
            }
            Form {
                TextField("Name", text: $contact.name)
                if contact.isSubContact {
                    TextField("Who they are", text: $contact.role, axis: .vertical).lineLimit(2...5)
                } else {
                    LabeledContent("Folder") {
                        HStack {
                            Text(contact.projectPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Change…", action: pickFolder)
                        }
                    }
                }
                Picker("Brain", selection: $contact.model) {
                    Text("Default").tag("")
                    Text("Opus").tag("opus")
                    Text("Sonnet").tag("sonnet")
                    Text("Haiku (fast, cheap)").tag("haiku")
                }
                Picker("Color", selection: $contact.colorIndex) {
                    ForEach(0..<Palette.gradients.count, id: \.self) { i in
                        Text(["Gray", "Orange", "Blue", "Green", "Purple", "Pink", "Yellow", "Teal"][i]).tag(i)
                    }
                }
                Toggle("Full access", isOn: $contact.fullAccess)
                Text(contact.fullAccess
                     ? "Can run any command in this project without asking. Only for projects you trust it with."
                     : "Can read and edit files in the project. Running commands gets blocked and you'll see a note.")
                    .font(.caption).foregroundStyle(contact.fullAccess ? .orange : .secondary)
            }
            .formStyle(.grouped)
            HStack {
                Button("Forget Memory") { store.forget(contact); dismiss() }
                    .help("Starts every chat with this contact fresh")
                Button("Delete", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { store.update(contact); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(contact.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .confirmationDialog("Delete \(contact.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(contact); dismiss() }
        } message: {
            Text(contact.isSubContact ? "Their chats go too." : "This also deletes its sub-contacts and their chats. The project folder is not touched.")
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: contact.projectPath)
        if panel.runModal() == .OK, let u = panel.url { contact.projectPath = u.path }
    }
}

// MARK: - New message / group

struct NewMessageSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [UUID] = []
    @State private var title = ""
    var existing: Conversation? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New Message" : "Group Info").font(.title2.bold())
            HStack(alignment: .firstTextBaseline) {
                Text("To:").foregroundStyle(.secondary)
                if picked.isEmpty {
                    Text("Pick one for a chat, two or more for a group").foregroundStyle(.tertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(picked, id: \.self) { id in
                                if let c = store.contact(id) {
                                    Text(store.displayName(c)).font(.callout)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Capsule().fill(Palette.blue.opacity(0.15)))
                                }
                            }
                        }
                    }
                }
            }
            if picked.count > 1 {
                TextField("Group name (optional)", text: $title)
            }
            List {
                ForEach(store.projects) { p in
                    toggleRow(p)
                    ForEach(store.subContacts(of: p.id)) { s in toggleRow(s).padding(.leading, 24) }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Start" : "Save") {
                    if let e = existing { store.setParticipants(e.id, picked, title: title) }
                    else { store.openGroup(picked, title: title) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .onAppear {
            if let e = existing { picked = e.participantIds; title = e.title ?? "" }
        }
    }

    private func toggleRow(_ c: Contact) -> some View {
        let on = picked.contains(c.id)
        return Button {
            if on { picked.removeAll { $0 == c.id } } else { picked.append(c.id) }
        } label: {
            HStack {
                Avatar(contact: c, size: 26)
                Text(c.name)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Palette.blue : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The header "i" sheet: contact info for a 1:1, group info for a group.
struct InfoSheet: View {
    @EnvironmentObject var store: Store
    let convId: UUID

    var body: some View {
        if let i = store.index(of: convId) {
            let conv = store.conversations[i]
            if conv.isGroup {
                NewMessageSheet(existing: conv)
            } else if let c = store.contact(conv.participantIds.first) {
                ContactEditor(contact: c)
            }
        }
    }
}
