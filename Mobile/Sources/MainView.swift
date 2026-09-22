import SwiftUI

/// iPad: chat list beside the open chat. iPhone: the same split collapses into a push stack.
struct MainView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var selected: UUID?
    @State private var renaming: Conversation?
    @State private var newName = ""
    @State private var showNew = false
    @State private var dropTarget: UUID?

    var body: some View {
        NavigationSplitView {
            list
                .navigationTitle("Messages")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Text(linkText)
                            Button("Unlink from Mac", role: .destructive) { client.unpair() }
                        } label: { Image(systemName: linkIcon).foregroundStyle(linkColor) }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                    }
                }
        } detail: {
            if let id = selected, client.conversation(id) != nil {
                ChatView(convId: id).id(id)
            } else {
                ContentUnavailableView("Pick a chat", systemImage: "message", description: Text("Your agents are waiting."))
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let r = renaming { client.rename(r.id, to: newName) }; renaming = nil }
            Button("Use Default Name") { if let r = renaming { client.rename(r.id, to: "") }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(isPresented: $showNew) { NewChatSheet { id in selected = id } }
        .onChange(of: selected) { _, id in if let id { client.markRead(id) } }
    }

    private var list: some View {
        List(selection: $selected) {
            if case .offline(let why) = client.link {
                Label(why, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
            }
            let pinned = client.conversations.filter(\.isPinned)
            if !pinned.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                    ForEach(pinned) { c in
                        Button { selected = c.id } label: { PinnedCell(conv: c) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(c) }
                    }
                }
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
            }
            ForEach(client.conversations.filter { !$0.isPinned }) { c in
                NavigationLink(value: c.id) { Row(conv: c) }
                    .contextMenu { menu(c) }
                    .swipeActions(edge: .leading) {
                        Button { client.togglePin(c.id) } label: { Label("Pin", systemImage: "pin") }.tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { client.hide(c.id) } label: { Label("Hide", systemImage: "eye.slash") }.tint(.gray)
                    }
                    .draggable(c.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let s = items.first.flatMap(UUID.init(uuidString:)), s != c.id else { return false }
                        Task { if let g = await client.merge(s, into: c.id) { selected = g } }
                        return true
                    } isTargeted: { on in
                        if on { dropTarget = c.id } else if dropTarget == c.id { dropTarget = nil }
                    }
                    .listRowBackground(dropTarget == c.id ? Palette.blue.opacity(0.2) : Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Clay.sidebar)
        .overlay {
            if client.snapshot == nil {
                ProgressView("Reaching \(client.pairing?.macName ?? "your Mac")…")
            }
        }
    }

    @ViewBuilder private func menu(_ c: Conversation) -> some View {
        Button { client.togglePin(c.id) } label: { Label(c.isPinned ? "Unpin" : "Pin", systemImage: c.isPinned ? "pin.slash" : "pin") }
        Button { newName = client.title(c); renaming = c } label: { Label("Rename", systemImage: "pencil") }
        Button { client.hide(c.id) } label: { Label("Hide (keeps memory)", systemImage: "eye.slash") }
    }

    private var linkText: String {
        switch client.link {
        case .online: return "Linked to \(client.snapshot?.macName ?? "your Mac")"
        case .connecting: return "Connecting…"
        case .offline(let why): return why
        case .unpaired: return "Not linked"
        }
    }
    private var linkIcon: String { client.link == .online ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark" }
    private var linkColor: Color { client.link == .online ? .green : .orange }
}

struct Row: View {
    @EnvironmentObject var client: RemoteClient
    let conv: Conversation

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(conv.unread ? Palette.blue : .clear).frame(width: 9, height: 9)
            GroupAvatar(ids: conv.participantIds, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(client.title(conv)).font(.headline).lineLimit(1)
                    if conv.usesCodex {
                        Text("Codex").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.black))
                    }
                    Spacer()
                    Text(conv.messages.last.map { shortDate($0.date) } ?? "").font(.caption).foregroundStyle(.secondary)
                }
                if let w = client.waitingFor(conv.id) {
                    Text("waiting for \(w)").font(.subheadline).foregroundStyle(Clay.inkSoft).lineLimit(1)
                } else if client.typing(in: conv.id) != nil {
                    TypingDots(dot: 6).padding(.horizontal, 9).padding(.vertical, 6)
                        .clayCapsule(Clay.cream, depth: 0.6)
                } else {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var preview: String {
        guard let m = conv.messages.last(where: { $0.kind != .system }) ?? conv.messages.last else { return "No messages yet" }
        if let f = m.from { return "\(f): \(m.text)" }
        if conv.isGroup, let s = client.contact(m.senderId) { return "\(s.name): \(m.text)" }
        return m.text
    }
}

struct PinnedCell: View {
    @EnvironmentObject var client: RemoteClient
    let conv: Conversation

    var body: some View {
        VStack(spacing: 5) {
            GroupAvatar(ids: conv.participantIds, size: 64)
                .overlay(alignment: .topTrailing) {
                    if client.typing(in: conv.id) != nil {
                        TypingDots(dot: 4).padding(.horizontal, 6).padding(.vertical, 5)
                            .clayCapsule(Clay.cream, depth: 0.7)
                            .offset(x: 8, y: -4)
                    } else if conv.unread {
                        Circle().fill(Palette.blue).frame(width: 13, height: 13)
                    }
                }
            Text(client.title(conv)).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct NewChatSheet: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    let opened: (UUID) -> Void
    @State private var engine: Engine = .claude
    @State private var model = ""
    @State private var newProject = ""

    var body: some View {
        NavigationStack {
            Picker("Talk to", selection: $engine) {
                ForEach(Engine.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal)
            .onChange(of: engine) { _, _ in model = "" }
            Picker("Model", selection: $model) {
                ForEach(client.models(for: engine)) { m in Text(m.label).tag(m.id) }
            }
            .padding(.horizontal)
            List {
                Section("New project") {
                    HStack {
                        TextField("Name", text: $newProject).textInputAutocapitalization(.words)
                        Button("Create") {
                            let n = newProject
                            Task {
                                if let id = await client.newProject(n, engine: engine, model: model) { opened(id) }
                                dismiss()
                            }
                        }
                        .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                let all = client.snapshot?.contacts ?? []
                ForEach(all.filter { $0.parentId == nil }.sorted { $0.name < $1.name }) { p in
                    Section(p.name) {
                        ForEach([p] + all.filter { $0.parentId == p.id }) { c in
                            Button {
                                Task {
                                    if let id = await client.openChat(with: c.id, engine: engine, model: model) { opened(id) }
                                    dismiss()
                                }
                            } label: {
                                HStack { Avatar(contact: c, size: 32); Text(c.parentId == nil ? "Main" : c.name).foregroundStyle(.primary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Message")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
