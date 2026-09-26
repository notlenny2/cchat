import SwiftUI
import AppKit

// MARK: - Contacts book

struct ContactsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Contact?
    @State private var addingSubTo: Contact?
    @State private var teamFor: Contact?
    @State private var expanded: Set<UUID> = []
    @State private var importNote: String?

    private var projectsRoot: URL { Prefs.projectsRoot }

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
                FirstProjectCard { dismiss() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.projects) { p in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(p.id) },
                            set: { if $0 { expanded.insert(p.id) } else { expanded.remove(p.id) } })) {
                            ForEach(store.subContacts(of: p.id)) { s in
                                row(s)
                            }
                            HStack(spacing: 14) {
                                Button { addingSubTo = p } label: {
                                    Label("New sub-contact", systemImage: "person.badge.plus")
                                }
                                Button { teamFor = p } label: {
                                    Label("Call in the team", systemImage: "person.3.fill")
                                }
                            }
                            .buttonStyle(.borderless).padding(.leading, 40)
                        } label: {
                            row(p)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 520, height: 560)
        .background(Clay.canvas)
        .foregroundStyle(Clay.ink)
        .sheet(item: $editing) { c in ContactEditor(contact: c).environmentObject(store) }
        .sheet(item: $addingSubTo) { p in SubContactSheet(project: p).environmentObject(store) }
        .sheet(item: $teamFor) { p in TeamSheet(project: p).environmentObject(store) }
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
        .background(Clay.canvas)
        .foregroundStyle(Clay.ink)
    }
}

// MARK: - Contact info / editor

struct ContactEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var contact: Contact
    @State private var confirmDelete = false
    @State private var callTeam = false

    var body: some View {
        VStack(spacing: 14) {
            Avatar(contact: contact, size: 64)
                .onDrop(of: ImageDrop.types, isTargeted: nil) { providers in
                    ImageDrop.load(Array(providers.prefix(1)), into: Store.photosDir) { paths in
                        if let p = paths.first { contact.iconPath = p; contact.iconSearched = true }
                    }
                    return true
                }
                .help("Drop a picture here")
            HStack(spacing: 12) {
                Button("Choose Picture…", action: pickPicture).buttonStyle(.link)
                if contact.iconPath != nil {
                    Button("Remove Picture") { contact.iconPath = nil; contact.iconSearched = true }.buttonStyle(.link)
                }
            }
            .font(.caption)
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
                if !contact.isSubContact {
                    Button("Call in the Team…") { callTeam = true }
                }
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
        .background(Clay.canvas)
        .foregroundStyle(Clay.ink)
        .sheet(isPresented: $callTeam) { TeamSheet(project: contact).environmentObject(store) }
        .confirmationDialog("Delete \(contact.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(contact); dismiss() }
        } message: {
            Text(contact.isSubContact ? "Their chats go too." : "This also deletes its sub-contacts and their chats. The project folder is not touched.")
        }
    }

    private func pickPicture() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: contact.projectPath)
        if panel.runModal() == .OK, let u = panel.url { contact.iconPath = u.path }
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
    @State private var engine: Engine = .claude
    @State private var model = ""
    @State private var newProject = ""
    @State private var creating = false
    @State private var createError: String?
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
            if existing == nil {
                HStack {
                    Text("Talk to:").foregroundStyle(.secondary)
                    Picker("", selection: $engine) {
                        ForEach(Engine.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    .disabled(engine == .claude && ClaudeRunner.codexPath == nil)
                    .onChange(of: engine) { _, _ in model = "" }
                    Spacer()
                    Picker("Model", selection: $model) {
                        ForEach(store.models(for: engine)) { m in Text(m.label).tag(m.id) }
                    }
                    .fixedSize()
                }
            } else if let e = existing {
                if e.isGroup {
                    Toggle("Let them talk to each other", isOn: Binding(
                        get: { store.conversation(e.id)?.letThemTalk ?? true },
                        set: { store.setChatter(e.id, on: $0) }))
                    Text("After they answer you, whoever has something to add can reply to the others for a few turns.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if e.usesCodex { Text("This chat runs on Codex.").font(.caption).foregroundStyle(.secondary) }
            }
            List {
                if existing == nil {
                    if creating {
                        HStack {
                            Image(systemName: "folder.badge.plus").foregroundStyle(Palette.blue).frame(width: 26)
                            TextField("New project name", text: $newProject).onSubmit(makeProject)
                            Button("Create", action: makeProject).disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if let createError { Text(createError).font(.caption).foregroundStyle(.red) }
                    } else {
                        Button { creating = true } label: {
                            Label("New Project…", systemImage: "folder.badge.plus").foregroundStyle(Palette.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(store.projects) { p in
                    toggleRow(p)
                    ForEach(store.subContacts(of: p.id)) { s in toggleRow(s).padding(.leading, 24) }
                }
                if existing == nil && !store.unaddedFolders.isEmpty {
                    Section("Other projects in your folder") {
                        ForEach(store.unaddedFolders, id: \.self) { u in
                            Button {
                                let c = store.addProject(path: u.path)
                                if !picked.contains(c.id) { picked.append(c.id) }
                            } label: {
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 26)
                                    Text(u.lastPathComponent)
                                    Spacer()
                                    Image(systemName: "circle").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Start" : "Save") {
                    if let e = existing { store.setParticipants(e.id, picked, title: title) }
                    else { store.openGroup(picked, title: title, engine: engine, model: model) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .background(Clay.canvas)
        .foregroundStyle(Clay.ink)
        .onAppear {
            if let e = existing { picked = e.participantIds; title = e.title ?? "" }
        }
    }

    private func makeProject() {
        do {
            let c = try store.createProject(named: newProject)
            if !picked.contains(c.id) { picked.append(c.id) }
            newProject = ""; creating = false; createError = nil
        } catch { createError = error.localizedDescription }
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
