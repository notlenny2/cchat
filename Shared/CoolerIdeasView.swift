import SwiftUI

/// One idea from a Water Cooler wrap-up. Lives in `cooler-ideas.json` next to store.json on the Mac.
struct CoolerIdea: Codable, Identifiable, Hashable {
    /// Optional so files written before ideas had ids still load; the Mac fills it in.
    var id: UUID?
    var app: String
    var text: String
    var night: String      // "Oct 5"
    var picked: Bool = true
    /// When it was handed to an agent ("Oct 13"), nil = not yet.
    var sent: String? = nil
    /// Filled in by the Mac when it hands the list over: the project contact this idea most likely belongs to.
    var to: UUID? = nil

    var key: UUID { id ?? UUID() }
}

/// The Ideas sheet (Mac and phone): every idea grouped by app, tick any number, send each to its project's chat.
/// The groups' destinations start at the Mac's best guess and can be changed per app.
struct CoolerIdeasView: View {
    let ideas: [CoolerIdea]
    /// Projects you can send to: id + name, sorted.
    let projects: [(id: UUID, name: String)]
    /// Sends these ideas to this project; returns the chat they landed in.
    let send: (_ ideas: [UUID], _ project: UUID) async -> UUID?
    /// Called when done: the chat to open (only when everything went to one chat).
    let finish: (UUID?) -> Void
    var openPage: (() -> Void)? = nil

    @State private var chosen: Set<UUID> = []
    @State private var dest: [String: UUID] = [:]
    @State private var hideSent = false
    @State private var sending = false

    private struct Group: Identifiable { let id: String; let app: String; let ideas: [CoolerIdea] }

    /// Apps in the order they first showed up, newest idea first inside each.
    private var groups: [Group] {
        var order: [String] = []
        for i in ideas where !order.contains(where: { $0.caseInsensitiveCompare(i.app) == .orderedSame }) { order.append(i.app) }
        return order.map { app in
            let list = ideas.filter { $0.app.caseInsensitiveCompare(app) == .orderedSame && !(hideSent && $0.sent != nil) }
            return Group(id: app.lowercased(), app: app, ideas: Array(list.reversed()))
        }.filter { !$0.ideas.isEmpty }
    }

    private func target(_ g: Group) -> UUID? { dest[g.id] ?? g.ideas.compactMap(\.to).first }
    private func name(_ id: UUID?) -> String? { projects.first { $0.id == id }?.name }

    /// Chosen ideas, bundled by where they're going.
    private var plan: [(project: UUID, ideas: [UUID])] {
        var out: [UUID: [UUID]] = [:], order: [UUID] = []
        for g in groups {
            guard let t = target(g) else { continue }
            let ids = g.ideas.compactMap(\.id).filter(chosen.contains)
            guard !ids.isEmpty else { continue }
            if out[t] == nil { order.append(t) }
            out[t, default: []] += ids
        }
        return order.map { ($0, out[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Water Cooler Ideas").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Clay.ink)
                Spacer()
                Toggle("Hide sent", isOn: $hideSent).toggleStyle(.switch).controlSize(.small)
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Clay.inkSoft)
                Button { finish(nil) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain).foregroundStyle(Clay.inkSoft)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
            Text("Tap ideas to pick them, then send. Each goes to that app's chat.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(Clay.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if groups.isEmpty {
                        Text(ideas.isEmpty ? "No ideas yet. They show up after a Water Cooler night." : "Everything's been sent.")
                            .font(.system(size: 15, design: .rounded)).foregroundStyle(Clay.inkSoft).padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(groups) { g in card(g) }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }

            footer
        }
        .background(Clay.canvas)
    }

    private func card(_ g: Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(g.app).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Clay.ink)
                Spacer()
                Menu {
                    ForEach(projects, id: \.id) { p in
                        Button { dest[g.id] = p.id } label: {
                            if target(g) == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane")
                        Text(name(target(g)).map { "To \($0)" } ?? "Pick a chat")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(target(g) == nil ? NeedsYouTag.color : Clay.terracotta)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .fixedSize()
            }
            .padding(.bottom, 6)
            ForEach(g.ideas, id: \.key) { i in row(i, sendable: target(g) != nil) }
        }
        .padding(16)
        .clay(Clay.cream, radius: 18, depth: 0.7)
    }

    private func row(_ i: CoolerIdea, sendable: Bool) -> some View {
        let on = i.id.map(chosen.contains) ?? false
        return Button {
            guard let id = i.id, sendable else { return }
            if on { chosen.remove(id) } else { chosen.insert(id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(on ? Clay.terracotta : Clay.inkSoft.opacity(sendable ? 0.7 : 0.3))
                VStack(alignment: .leading, spacing: 4) {
                    Text((i.picked ? "★ " : "") + i.text)
                        .font(.system(size: 14, weight: i.picked ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(Clay.ink.opacity(i.sent == nil ? 1 : 0.55))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        chip(i.night, Clay.peach, Clay.inkSoft)
                        if let s = i.sent { chip("Sent \(s)", Clay.terracotta.opacity(0.18), Clay.terracotta) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ s: String, _ bg: Color, _ fg: Color) -> some View {
        Text(s).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(bg))
    }

    private var footer: some View {
        let p = plan
        let count = p.reduce(0) { $0 + $1.ideas.count }
        let names = p.compactMap { name($0.project) }
        return HStack(spacing: 12) {
            if let openPage { Button("Open as Web Page", action: openPage).buttonStyle(.borderless).font(.system(size: 12, design: .rounded)) }
            Spacer()
            if count > 0 {
                Text(names.count == 1 ? "to \(names[0])" : "to \(names.count) chats").font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Clay.inkSoft).lineLimit(1)
            }
            Button {
                sending = true
                Task {
                    var landed: [UUID] = []
                    for (project, ids) in p { if let c = await send(ids, project) { landed.append(c) } }
                    sending = false
                    chosen = []
                    finish(Set(landed).count == 1 ? landed.first : nil)
                }
            } label: {
                Text(sending ? "Sending…" : count == 0 ? "Send" : "Send \(count) idea\(count == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(count == 0 || sending ? Clay.inkSoft.opacity(0.4) : Clay.terracotta))
            }
            .buttonStyle(.plain).disabled(count == 0 || sending)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Clay.sidebar)
    }
}
