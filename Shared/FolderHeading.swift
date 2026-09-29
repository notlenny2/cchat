import SwiftUI

/// A project's heading in the chat list: tap to fold it away, drop a chat on it to file the chat there.
/// Project heading in the chat list. Biggest thing in the list: project > group chat > single chat.
enum FolderHeadingSize { static let avatar: CGFloat = 34 }

struct FolderHeading<Avatar: View>: View {
    static var avatarSize: CGFloat { FolderHeadingSize.avatar }
    let folder: ChatFolders.Folder
    let open: Bool
    var target = false
    let toggle: () -> Void
    @ViewBuilder var avatar: () -> Avatar

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(Clay.inkSoft).frame(width: 10)
                if folder.project == nil {
                    Image(systemName: "tray.full").font(.system(size: 18)).foregroundStyle(Clay.inkSoft).frame(width: FolderHeading.avatarSize, height: FolderHeading.avatarSize)
                } else {
                    avatar().frame(width: FolderHeading.avatarSize, height: FolderHeading.avatarSize)
                }
                Text(folder.name).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Clay.ink).lineLimit(1)
                Spacer(minLength: 4)
                if target {
                    Text("Drop to file here").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Clay.terracotta))
                } else {
                    if !open, folder.convs.contains(where: { $0.unread || $0.needsYou != nil }) {
                        Circle().fill(folder.convs.contains { $0.needsYou != nil } ? NeedsYouTag.color : Clay.terracotta)
                            .frame(width: 8, height: 8)
                    }
                    Text("\(folder.convs.count)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Clay.inkSoft)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Clay.peach))
                }
            }
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(target ? Clay.terracotta.opacity(0.22) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(target ? Clay.terracotta : .clear, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(folder.name), \(folder.convs.count) chats, \(open ? "open" : "folded")")
    }
}
