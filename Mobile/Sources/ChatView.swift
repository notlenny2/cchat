import SwiftUI

struct ChatView: View {
    @EnvironmentObject var client: RemoteClient
    let convId: UUID
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let conv = client.conversation(convId) {
            VStack(spacing: 0) {
                transcript(conv)
                composer(conv)
            }
            .navigationTitle(client.title(conv))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        GroupAvatar(ids: conv.participantIds, size: 30)
                        Text(client.title(conv)).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                }
                if client.isBusy(convId) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Stop", role: .destructive) { client.stopReply(convId) }.tint(.red)
                    }
                }
            }
        }
    }

    private func transcript(_ conv: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(conv.messages.enumerated()), id: \.element.id) { idx, m in
                        let prev = idx > 0 ? conv.messages[idx - 1] : nil
                        let next = idx + 1 < conv.messages.count ? conv.messages[idx + 1] : nil
                        if prev == nil || m.date.timeIntervalSince(prev!.date) > 15 * 60 {
                            Text(m.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 12).padding(.bottom, 4)
                        }
                        Bubble(message: m, isGroup: conv.isGroup,
                               firstInRun: prev?.senderId != m.senderId || prev?.kind == .system,
                               lastInRun: next?.senderId != m.senderId || next?.kind == .system)
                    }
                    if let t = client.typing(in: convId) {
                        HStack(alignment: .bottom, spacing: 8) {
                            if conv.isGroup { Avatar(contact: client.contact(t), size: 28) }
                            TypingDots().padding(.horizontal, 14).padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
                            Spacer()
                        }
                        .padding(.top, 6)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: conv.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: client.typing(in: convId)) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    private func composer(_ conv: Conversation) -> some View {
        VStack(spacing: 8) {
            if !conv.suggestions.isEmpty && client.typing(in: convId) == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(conv.suggestions, id: \.self) { s in
                            Button { client.send(s, in: convId) } label: {
                                Text(s).font(.callout).padding(.horizontal, 12).padding(.vertical, 7)
                                    .foregroundStyle(Palette.blue)
                                    .background(Capsule().strokeBorder(Palette.blue.opacity(0.6)))
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("cChat", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.secondary.opacity(0.35)))
                Button {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    draft = ""
                    client.send(t, in: convId)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.4) : Palette.blue)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct Bubble: View {
    @EnvironmentObject var client: RemoteClient
    let message: Message
    let isGroup: Bool
    let firstInRun: Bool
    let lastInRun: Bool

    private var mine: Bool { message.senderId == nil }

    var body: some View {
        if message.kind == .system {
            Text(message.text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.vertical, 6).frame(maxWidth: .infinity)
        } else {
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if isGroup && !mine && firstInRun, let c = client.contact(message.senderId) {
                    Text(c.displayName).font(.caption2).foregroundStyle(.secondary).padding(.leading, 48)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if mine { Spacer(minLength: 60) }
                    if isGroup && !mine {
                        if lastInRun { Avatar(contact: client.contact(message.senderId), size: 28) }
                        else { Color.clear.frame(width: 28, height: 1) }
                    }
                    Text(rendered)
                        .textSelection(.enabled)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .foregroundStyle(mine ? .white : .primary)
                        .background(bubble)
                    if !mine { Spacer(minLength: 60) }
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
        else { shape.fill(Color(uiColor: .secondarySystemBackground)) }
    }
}
