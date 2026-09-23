import SwiftUI
import AVKit

struct ChatView: View {
    @EnvironmentObject var client: RemoteClient
    let convId: UUID
    @State private var draft = ""
    @State private var scrolledUp = false
    @FocusState private var focused: Bool

    var body: some View {
        if let conv = client.conversation(convId) {
            VStack(spacing: 0) {
                transcript(conv)
                composer(conv)
            }
            .background(Clay.canvas)
            .foregroundStyle(Clay.ink)
            .navigationTitle(client.title(conv))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        GroupAvatar(ids: conv.participantIds, size: 30)
                        Text(client.title(conv)).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if conv.isGroup {
                            Button {
                                client.setChatter(convId, on: !conv.letThemTalk)
                            } label: {
                                Label(conv.letThemTalk ? "Stop them talking to each other" : "Let them talk to each other",
                                      systemImage: conv.letThemTalk ? "person.2.slash" : "person.2.wave.2")
                            }
                            if conv.participantIds.count > 2 {
                                Menu {
                                    ForEach(conv.participantIds, id: \.self) { id in
                                        Button(client.contact(id)?.name ?? "Someone", role: .destructive) {
                                            client.removeFromGroup(convId, id)
                                        }
                                    }
                                } label: { Label("Take someone out", systemImage: "person.badge.minus") }
                            }
                            Divider()
                        }
                        ForEach(client.models(for: conv.engine ?? .claude)) { m in
                            Button { client.setModel(convId, m.id) } label: {
                                if (conv.model ?? "") == m.id { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                            }
                        }
                    } label: { Label(client.modelSummary(conv), systemImage: "cpu") }
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
                    let shown = conv.messages.squishedJoins
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, m in
                        let prev = idx > 0 ? shown[idx - 1] : nil
                        let next = idx + 1 < shown.count ? shown[idx + 1] : nil
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
                            TypingDots().padding(.horizontal, 15).padding(.vertical, 12)
                                .clay(Clay.cream, radius: 20)
                            if let w = client.waitingFor(convId) {
                                Text("waiting for \(w)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.top, 6)
                    }
                    Color.clear.frame(height: 4).id("bottom").reportsChatBottom()
                }
                .padding(.horizontal, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .jumpToLatest($scrolledUp) { toBottom(proxy) }
            .onChange(of: conv.messages.count) { _, _ in toBottom(proxy) }
            .onChange(of: client.typing(in: convId)) { _, _ in toBottom(proxy) }
            // The chips appearing under a reply shrink the transcript, which left the end of a reply cut off.
            .onChange(of: conv.suggestions) { _, _ in toBottom(proxy) }
        }
    }

    /// Scrolls to the end, then again once pictures and the chips have taken their real size.
    private func toBottom(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func composer(_ conv: Conversation) -> some View {
        VStack(spacing: 8) {
            if !conv.suggestions.isEmpty && client.typing(in: convId) == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(conv.suggestions, id: \.self) { s in
                            Button { client.send(s, in: convId) } label: {
                                Text(s).font(.callout.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 8)
                                    .foregroundStyle(Clay.terracotta)
                                    .clayCapsule(Clay.cream, depth: 0.7)
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
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Clay.cream)
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(LinearGradient(colors: [Clay.shadow.opacity(0.22), .white.opacity(0.6)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
                    )
                Button {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    draft = ""
                    client.send(t, in: convId)
                } label: {
                    let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(empty ? 0.7 : 1))
                        .frame(width: 38, height: 38)
                        .background(ClaySurface(shape: Circle(), color: empty ? Clay.inkSoft.opacity(0.45) : Clay.terracotta, depth: empty ? 0.4 : 1))
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Clay.sidebar.opacity(0.6))
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
                if let f = message.from {
                    Text("\(f), on your behalf").font(.caption2).foregroundStyle(.secondary).padding(.trailing, 12)
                }
                if isGroup && !mine && firstInRun, let c = client.contact(message.senderId) {
                    Text(c.displayName).font(.caption2).foregroundStyle(.secondary).padding(.leading, 48)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if mine { Spacer(minLength: 60) }
                    if isGroup && !mine {
                        if lastInRun { Avatar(contact: client.contact(message.senderId), size: 28) }
                        else { Color.clear.frame(width: 28, height: 1) }
                    }
                    VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                        // Your pictures sit above your note (like Messages); an agent's words come first, since
                        // they usually lead into the picture ("Here's how it looks:").
                        if !mine, !message.text.isEmpty { bubbleText }
                        ForEach(message.attachments ?? [], id: \.self) { RemoteMedia(name: $0) }
                        if mine, !message.text.isEmpty { bubbleText }
                    }
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

    private var bubbleText: some View {
        Text(rendered)
            .textSelection(.enabled)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .foregroundStyle(mine ? .white : Clay.ink)
            .background(bubble)
    }

    private var rendered: AttributedString {
        (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }

    @ViewBuilder private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if mine { ClaySurface(shape: shape, color: message.from == nil ? Clay.terracotta : Clay.plum) }
        else if message.kind == .error { ClaySurface(shape: shape, color: Color(red: 0.96, green: 0.80, blue: 0.76), depth: 0.6) }
        else { ClaySurface(shape: shape, color: Clay.cream) }
    }
}

/// A picture or video from the chat, fetched from the Mac the first time it's shown.
struct RemoteMedia: View {
    @EnvironmentObject var client: RemoteClient
    let name: String
    @State private var url: URL?
    @State private var failed = false
    @State private var player: AVPlayer?

    private var isVideo: Bool { ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) }

    var body: some View {
        Group {
            if let url {
                if isVideo {
                    VideoPlayer(player: player).frame(width: 260, height: 170)
                        .onAppear { if player == nil { player = AVPlayer(url: url) } }
                } else if let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 300)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.15))
                    if failed { Label(isVideo ? "Video" : "Picture", systemImage: "exclamationmark.triangle").font(.caption) }
                    else { ProgressView() }
                }
                .frame(width: 200, height: 140)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task { if url == nil { url = await client.media(name); failed = url == nil } }
    }
}
