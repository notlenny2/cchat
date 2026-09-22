import SwiftUI

struct ChatView: View {
    @EnvironmentObject var store: Store
    let convId: UUID
    @State private var draft = ""
    @State private var showInfo = false
    @FocusState private var focused: Bool

    private var conv: Conversation? { store.index(of: convId).map { store.conversations[$0] } }

    var body: some View {
        if let conv {
            VStack(spacing: 0) {
                header(conv)
                Divider()
                transcript(conv)
                composer(conv)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .sheet(isPresented: $showInfo) { InfoSheet(convId: convId).environmentObject(store) }
            .onAppear { focused = true; store.markRead(convId) }
        }
    }

    // MARK: Header

    private func header(_ conv: Conversation) -> some View {
        HStack {
            Spacer()
            Button { showInfo = true } label: {
                VStack(spacing: 3) {
                    GroupAvatar(ids: conv.participantIds, size: 44)
                    HStack(spacing: 2) {
                        Text(store.title(for: conv)).font(.caption.weight(.medium)).foregroundStyle(.primary)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                    if let sub = subtitle(conv) {
                        Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .overlay(alignment: .trailing) {
            if store.isBusy(convId) {
                Button("Stop") { store.stop(convId) }
                    .buttonStyle(.borderless).foregroundStyle(.red).padding(.trailing, 16)
            }
        }
        .padding(.vertical, 10)
    }

    private func subtitle(_ conv: Conversation) -> String? {
        if conv.isGroup { return "\(conv.participantIds.count) agents" }
        guard let c = store.contact(conv.participantIds.first) else { return nil }
        return URL(fileURLWithPath: c.projectPath).lastPathComponent + (c.fullAccess ? " · full access" : "")
    }

    // MARK: Transcript

    private func transcript(_ conv: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(conv.messages.enumerated()), id: \.element.id) { idx, m in
                        let prev = idx > 0 ? conv.messages[idx - 1] : nil
                        let next = idx + 1 < conv.messages.count ? conv.messages[idx + 1] : nil
                        if prev == nil || m.date.timeIntervalSince(prev!.date) > 15 * 60 {
                            Text(timestamp(m.date)).font(.caption2).foregroundStyle(.secondary).padding(.top, 12).padding(.bottom, 4)
                        }
                        MessageRow(message: m, isGroup: conv.isGroup,
                                   firstInRun: prev?.senderId != m.senderId || prev?.kind == .system,
                                   lastInRun: next?.senderId != m.senderId || next?.kind == .system)
                    }
                    if let t = store.typing[convId] {
                        TypingRow(contact: store.contact(t), isGroup: conv.isGroup).id("typing")
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conv.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: store.typing[convId]) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    private func timestamp(_ d: Date) -> String {
        Calendar.current.isDateInToday(d)
            ? "Today " + d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    // MARK: Composer

    private func composer(_ conv: Conversation) -> some View {
        VStack(spacing: 8) {
            if !conv.suggestions.isEmpty && store.typing[convId] == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(conv.suggestions, id: \.self) { s in
                            Button { store.send(s, in: convId) } label: {
                                Text(s).font(.callout)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .foregroundStyle(Palette.blue)
                                    .background(Capsule().strokeBorder(Palette.blue.opacity(0.6), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("cMessage", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(sendDraft)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.secondary.opacity(0.35)))
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.4) : Palette.blue)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.2), value: conv.suggestions)
    }

    private func sendDraft() {
        let t = draft
        draft = ""
        store.send(t, in: convId)
    }
}

// MARK: - Bubbles

struct MessageRow: View {
    @EnvironmentObject var store: Store
    let message: Message
    let isGroup: Bool
    let firstInRun: Bool
    let lastInRun: Bool

    private var mine: Bool { message.senderId == nil }

    var body: some View {
        if message.kind == .system {
            Text(message.text).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.vertical, 6).frame(maxWidth: .infinity)
        } else {
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if isGroup && !mine && firstInRun, let c = store.contact(message.senderId) {
                    Text(store.displayName(c)).font(.caption2).foregroundStyle(.secondary).padding(.leading, 48)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if mine { Spacer(minLength: 80) }
                    if isGroup && !mine {
                        if lastInRun { Avatar(contact: store.contact(message.senderId), size: 28) }
                        else { Color.clear.frame(width: 28, height: 1) }
                    }
                    Text(rendered)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(mine ? .white : .primary)
                        .background(bubble)
                    if !mine { Spacer(minLength: 80) }
                }
                if message.kind == .error {
                    Label("Not Delivered", systemImage: "exclamationmark.circle.fill")
                        .font(.caption2).foregroundStyle(.red).padding(.leading, isGroup ? 48 : 12)
                }
            }
            .padding(.top, firstInRun ? 6 : 0)
        }
    }

    private var rendered: AttributedString {
        (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }

    @ViewBuilder private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if mine { shape.fill(Palette.blue) }
        else if message.kind == .error { shape.fill(Color.red.opacity(0.15)) }
        else { shape.fill(Color(nsColor: .controlBackgroundColor)).overlay(shape.strokeBorder(Color.secondary.opacity(0.12))) }
    }
}

struct TypingRow: View {
    let contact: Contact?
    let isGroup: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isGroup { Avatar(contact: contact, size: 28) }
            TypingDots(dot: 7)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            if isGroup, let c = contact { Text("\(c.name) is typing").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.top, 6)
    }
}

/// The three pulsing dots, used in the chat, the chat list and on pinned avatars.
struct TypingDots: View {
    var dot: CGFloat = 7

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * 5
            HStack(spacing: dot * 0.55) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary)
                        .frame(width: dot, height: dot)
                        .opacity(0.3 + 0.7 * max(0, sin(t - Double(i) * 0.9)))
                }
            }
        }
    }
}
