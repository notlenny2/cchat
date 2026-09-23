import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Pictures and videos an agent wants the user to see. Agents mark them with `<<show: /path/or/url>>`;
/// cChat copies each one into its own attachments folder so it survives the agent tidying up.
enum Media {
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v"]
    static let maxBytes = 1_000_000_000

    static func isVideo(_ path: String) -> Bool { videoExts.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }

    /// Pulls `<<show: ...>>` markers (and markdown images `![](...)`) out of a reply.
    static func extract(from text: String) -> (String, [String]) {
        var body = text
        var refs: [String] = []
        for pattern in [#"<<\s*show\s*:\s*(.+?)\s*>>"#, #"!\[[^\]]*\]\(([^)\s]+)\)"#] {
            let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let ns = body as NSString
            for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)).reversed() {
                refs.insert(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'` ")), at: 0)
                body = (body as NSString).replacingCharacters(in: m.range, with: "")
            }
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), refs)
    }

    /// Copies a local file or downloads a URL into cChat's folder. Only real pictures and videos are kept,
    /// so an agent can't use this to surface some other file.
    static func importRef(_ ref: String, relativeTo cwd: String) async -> String? {
        if let url = URL(string: ref), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let mime = (resp as? HTTPURLResponse)?.mimeType ?? ""
                let ext = mime.hasPrefix("video/") ? (mime.contains("quicktime") ? "mov" : "mp4")
                    : mime.hasPrefix("image/") ? "png" : url.pathExtension.lowercased()
                return copyIn(tmp, ext: ext)
            } catch { Log.error("media download failed \(url.host ?? ""): \(error)"); return nil }
        }
        let expanded = (ref as NSString).expandingTildeInPath
        let path = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        return copyIn(URL(fileURLWithPath: path), ext: URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func copyIn(_ src: URL, ext: String) -> String? {
        let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard FileManager.default.fileExists(atPath: src.path), size > 0, size < maxBytes else {
            Log.error("media missing or too big: \(src.lastPathComponent)"); return nil
        }
        if videoExts.contains(ext) {
            guard AVURLAsset(url: src).tracks(withMediaType: .video).isEmpty == false else { return nil }
            let dest = Store.attachmentsDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            do { try FileManager.default.copyItem(at: src, to: dest); return dest.path }
            catch { Log.error("video copy failed: \(error)"); return nil }
        }
        return Store.importImage(src, into: Store.attachmentsDir)
    }

    /// First frame of a video, for the bubble before it's played.
    static func poster(_ path: String) -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Plays a chat video in its own plain AppKit window. SwiftUI's VideoPlayer inside the chat crashed the app
/// (an endless "update constraints" loop between it and the chat's layout, 0.1.2), so the player never sits in
/// the SwiftUI tree at all.
@MainActor
enum VideoWindow {
    private static var window: NSWindow?

    static func play(_ path: String) {
        let player = AVPlayer(url: URL(fileURLWithPath: path))
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        let size = videoSize(path)
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            window = w
            return w
        }()
        (w.contentView as? AVPlayerView)?.player?.pause()
        w.contentView = view
        w.title = URL(fileURLWithPath: path).lastPathComponent
        w.setContentSize(size)
        w.contentAspectRatio = size
        w.center()
        w.makeKeyAndOrderFront(nil)
        player.play()
    }

    /// The video's own shape, scaled to fit comfortably on screen.
    private static func videoSize(_ path: String) -> NSSize {
        let track = AVURLAsset(url: URL(fileURLWithPath: path)).tracks(withMediaType: .video).first
        var s = track.map { $0.naturalSize.applying($0.preferredTransform) } ?? CGSize(width: 16, height: 9)
        s = CGSize(width: abs(s.width), height: abs(s.height))
        let k = min(960 / max(s.width, 1), 640 / max(s.height, 1))
        return NSSize(width: s.width * k, height: s.height * k)
    }
}

/// A picture or video inside a message bubble. Videos show their first frame; clicking plays it in a player window.
struct MediaView: View {
    let path: String
    @State private var poster: NSImage?

    var body: some View {
        Group {
            if Media.isVideo(path) {
                ZStack {
                    if let poster { Image(nsImage: poster).resizable().scaledToFit() }
                    else { Color.black }
                    Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
                .frame(width: 320, height: 200)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { VideoWindow.play(path) }
                .task { if poster == nil { poster = Media.poster(path) } }
            } else if let img = IconCache.image(path) {
                // Sized exactly to the picture: a 320x320 box centered a narrow one, so it sat indented from the bubbles.
                let k = min(320 / max(img.size.width, 1), 320 / max(img.size.height, 1))
                Image(nsImage: img).resizable().scaledToFit().frame(width: img.size.width * k, height: img.size.height * k)
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider() }
    }
}
