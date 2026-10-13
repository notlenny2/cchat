import AppKit
import UniformTypeIdentifiers

/// Accepts pictures dragged from anywhere: Finder files, and apps like Messages, Photos and Safari,
/// which hand over the picture itself (often as a "promised" file that only exists for a moment)
/// rather than a file on disk. Every picture is copied into cChat's own folder as a PNG.
enum ImageDrop {
    static let types: [UTType] = [.fileURL, .image]

    static func load(_ providers: [NSItemProvider], into dir: URL, done: @escaping @MainActor ([String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [(Int, String)] = []
        func add(_ i: Int, _ p: String?) { if let p { lock.lock(); paths.append((i, p)); lock.unlock() } }

        for (i, p) in providers.enumerated() {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    add(i, url.flatMap { Store.importImage($0, into: dir) })
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // The temp file is deleted when this callback returns, so copy it right here.
                p.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, err in
                    if let url {
                        add(i, Store.importImage(url, into: dir))
                        group.leave()
                    } else {
                        p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, err2 in
                            add(i, data.flatMap { Store.importImage(data: $0, into: dir) })
                            if data == nil { Log.error("picture drop failed: \(String(describing: err2 ?? err))") }
                            group.leave()
                        }
                    }
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ordered = paths.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { done(ordered) }
        }
    }

    /// Pictures on the clipboard (a copied screenshot, an image copied in Safari or Preview, picture files copied
    /// in Finder), copied into `dir`. nil when the clipboard holds no pictures, so a normal text paste goes ahead.
    /// Text wins when there's both: Word and friends put a picture of the copied text on the clipboard too.
    static func paste(from pb: NSPasteboard = .general, into dir: URL) -> [String]? {
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true }
        if !files.isEmpty {
            let paths = files.prefix(10).compactMap { Store.importImage($0, into: dir) }
            return paths.isEmpty ? nil : paths
        }
        guard pb.string(forType: .string) == nil else { return nil }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = pb.data(forType: type), let p = Store.importImage(data: data, into: dir) { return [p] }
        }
        return nil
    }
}

/// Command-V in a chat with a picture on the clipboard: the picture waits above the text box, like a drop.
/// Watches key presses in this app only; anything that isn't a picture paste passes straight through.
final class PicturePaste {
    private var monitor: Any?

    func start(_ added: @escaping @MainActor ([String]) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let window = event.window, !window.isSheet, window.attachedSheet == nil,
                  // The terminal drawer has its own paste.
                  !String(describing: type(of: window.firstResponder as Any)).contains("Terminal"),
                  let paths = ImageDrop.paste(into: Store.attachmentsDir) else { return event }
            MainActor.assumeIsolated { added(paths) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
