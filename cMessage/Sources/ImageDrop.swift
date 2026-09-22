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
}
