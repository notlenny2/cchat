import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var showNew = false
    @State private var showContacts = false

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
        .sheet(isPresented: $showNew) { NewMessageSheet().environmentObject(store) }
        .sheet(isPresented: $showContacts) { ContactsSheet().environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .newMessage)) { _ in showNew = true }
        .onReceive(NotificationCenter.default.publisher(for: .showContacts)) { _ in showContacts = true }
        .onAppear { if store.contacts.isEmpty { showContacts = true } }
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
            ForEach(filtered) { c in
                ConversationRow(conv: c)
                    .tag(c.id)
                    .contextMenu {
                        Button("Hide Chat (keeps memory)") { store.hide(c.id) }
                        Button("Delete Chat and Memory", role: .destructive) { store.deleteForever(c.id) }
                    }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup {
                Button { showContacts = true } label: { Image(systemName: "person.crop.circle") }
                    .help("Contacts")
                Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                    .help("New Message")
            }
        }
        .onChange(of: store.selectedId) { _, id in if let id { store.markRead(id) } }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "message.fill")
                .font(.system(size: 54))
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.4, green: 0.85, blue: 0.4), Color(red: 0.15, green: 0.7, blue: 0.3)], startPoint: .top, endPoint: .bottom))
            Text(store.contacts.isEmpty ? "Add a project to start texting it." : "Pick a chat, or start a new one.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Contacts") { showContacts = true }
                Button("New Message") { showNew = true }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationRow: View {
    @EnvironmentObject var store: Store
    let conv: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(conv.unread ? Palette.blue : .clear).frame(width: 8, height: 8).padding(.top, 16)
            GroupAvatar(ids: conv.participantIds, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(store.title(for: conv)).font(.headline).lineLimit(1)
                    Spacer()
                    Text(conv.messages.last.map { shortDate($0.date) } ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        if let t = store.typing[conv.id], let c = store.contact(t) {
            return conv.isGroup ? "\(c.name) is typing…" : "Typing…"
        }
        guard let m = conv.messages.last(where: { $0.kind != .system }) ?? conv.messages.last else { return "No messages yet" }
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
