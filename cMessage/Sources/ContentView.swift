import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var showNew = false
    @State private var showContacts = false
    @State private var showPairing = false
    @State private var showSetup = !Prefs.setupDone
    @State private var renaming: Conversation?
    @State private var newName = ""
    @State private var dropTarget: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            if let id = store.selectedId, store.index(of: id) != nil {
                ChatView(convId: id).id(id)
            } else {
                emptyState
            }
        }
        // No stock white title bar over the chat: the chat header's color runs up under it.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showNew) { NewMessageSheet().environmentObject(store) }
        .sheet(isPresented: $showContacts) { ContactsSheet().environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .newMessage)) { _ in showNew = true }
        .onReceive(NotificationCenter.default.publisher(for: .showContacts)) { _ in showContacts = true }
        .onReceive(NotificationCenter.default.publisher(for: .showPairing)) { _ in showPairing = true }
        .sheet(isPresented: $showPairing) { PairingSheet() }
        .sheet(isPresented: $showSetup) {
            SetupView { showSetup = false; if store.contacts.isEmpty { showContacts = true } }
                .interactiveDismissDisabled()
        }
        .onAppear { if Prefs.setupDone && store.contacts.isEmpty { showContacts = true } }
    }

    private var filtered: [Conversation] {
        let all = store.visibleConversations
        guard !search.isEmpty else { return all }
        return all.filter { c in
            store.title(for: c).localizedCaseInsensitiveContains(search)
                || c.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    private var sidebar: some View {
        List(selection: $store.selectedId) {
            let pinned = search.isEmpty ? store.pinnedConversations : []
            if !pinned.isEmpty {
                PinnedGrid(convs: pinned, selected: $store.selectedId)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            ForEach(filtered.filter { !search.isEmpty || !$0.isPinned }) { c in
                ConversationRow(conv: c)
                    .tag(c.id)
                    .contextMenu { chatMenu(c) }
                    .draggable(c.id.uuidString) {
                        HStack { GroupAvatar(ids: c.participantIds, size: 28, photo: c.photoPath); Text(store.title(for: c)) }
                            .padding(6).background(.regularMaterial, in: Capsule())
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let s = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                        return withAnimation { store.merge(s, into: c.id) != nil }
                    } isTargeted: { on in
                        if on { dropTarget = c.id } else if dropTarget == c.id { dropTarget = nil }
                    }
                    .listRowBackground(dropTarget == c.id ? RoundedRectangle(cornerRadius: 8).fill(Palette.blue.opacity(0.25)) : nil)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Clay.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup {
                if Flavor.personal {
                    Button { showPairing = true } label: { Image(systemName: "iphone") }
                        .help("Connect iPhone or iPad")
                }
                Button { showContacts = true } label: { Image(systemName: "person.crop.circle") }
                    .help("Contacts")
                Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                    .help("New Message")
            }
        }
        .onChange(of: store.selectedId) { _, id in if let id { store.markRead(id) } }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let r = renaming { store.rename(r.id, to: newName) }; renaming = nil }
            Button("Use Default Name") { if let r = renaming { store.rename(r.id, to: "") }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Tip: drag one chat onto another to put them in a group.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .renameChat)) { n in
            if let id = n.object as? UUID, let c = store.conversations.first(where: { $0.id == id }) {
                newName = store.title(for: c); renaming = c
            }
        }
    }

    @ViewBuilder private func chatMenu(_ c: Conversation) -> some View {
        Button(c.isPinned ? "Unpin" : "Pin") { withAnimation { store.togglePin(c.id) } }
        Button("Rename…") { newName = store.title(for: c); renaming = c }
        Divider()
        Button("Hide Chat (keeps memory)") { store.hide(c.id) }
        Button("Delete Chat and Memory", role: .destructive) { store.deleteForever(c.id) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "message.fill")
                .font(.system(size: 54))
                .hidden()
                .overlay(
                    HStack(spacing: 7) { ClayDimple(size: 12); ClayDimple(size: 12); ClayDimple(size: 12) }
                        .padding(.horizontal, 26).padding(.vertical, 20)
                        .clay(Clay.terracotta, radius: 26)
                )
            Text(store.contacts.isEmpty ? "Add a project to start texting it." : "Pick a chat, or start a new one.")
                .foregroundStyle(Clay.inkSoft)
            HStack {
                Button("Contacts") { showContacts = true }
                Button("New Message") { showNew = true }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Clay.canvas.ignoresSafeArea())
    }
}

struct ConversationRow: View {
    @EnvironmentObject var store: Store
    let conv: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(conv.unread ? Palette.blue : .clear).frame(width: 8, height: 8).padding(.top, 16)
            GroupAvatar(ids: conv.participantIds, size: 40, photo: conv.photoPath)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(store.title(for: conv)).font(.headline).lineLimit(1).foregroundStyle(Clay.ink)
                    EngineBadge(conv: conv)
                    Spacer()
                    Text(conv.messages.last.map { shortDate($0.date) } ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let w = store.waitingFor[conv.id] {
                    Text("waiting for \(w)").font(.subheadline).foregroundStyle(Clay.inkSoft).lineLimit(1)
                } else if store.typing[conv.id] != nil {
                    HStack(spacing: 6) {
                        TypingDots(dot: 6)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .clayCapsule(Clay.cream, depth: 0.6)
                        if conv.isGroup, let c = store.contact(store.typing[conv.id]) {
                            Text(c.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else {
                    Text(preview).font(.subheadline).foregroundStyle(Clay.inkSoft).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        guard let m = conv.messages.last(where: { $0.kind != .system }) ?? conv.messages.last else { return "No messages yet" }
        if let f = m.from { return "\(f): \(m.text)" }
        if conv.isGroup, let s = store.contact(m.senderId) { return "\(s.name): \(m.text)" }
        return m.text
    }
}

func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    return d.formatted(date: .numeric, time: .omitted)
}

/// iMessage-style pinned row: big avatars, name underneath, typing dots bubble on top.
struct PinnedGrid: View {
    @EnvironmentObject var store: Store
    let convs: [Conversation]
    @Binding var selected: UUID?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 12) {
            ForEach(convs) { c in
                Button { selected = c.id } label: {
                    VStack(spacing: 4) {
                        GroupAvatar(ids: c.participantIds, size: 58, photo: c.photoPath)
                            .overlay(alignment: .topTrailing) {
                                if store.typing[c.id] != nil {
                                    TypingDots(dot: 4)
                                        .padding(.horizontal, 6).padding(.vertical, 5)
                                        .clayCapsule(Clay.cream, depth: 0.7)
                                        .offset(x: 8, y: -4)
                                }
                            }
                            .overlay(Circle().stroke(selected == c.id ? Palette.blue : .clear, lineWidth: 2.5).padding(-3))
                        HStack(spacing: 4) {
                            if c.unread { Circle().fill(Palette.blue).frame(width: 7, height: 7) }
                            Text(store.title(for: c)).font(.caption).lineLimit(1)
                                .foregroundStyle(selected == c.id ? Clay.terracotta : Clay.ink)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Unpin") { withAnimation { store.togglePin(c.id) } }
                }
            }
        }
        .padding(.vertical, 8)
    }
}
