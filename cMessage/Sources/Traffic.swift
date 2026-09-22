import Foundation

/// Air traffic control for project folders.
///
/// Several chats can point at the same folder (a project and its specialists, a group, a personal build and
/// the public one, two windows). Letting them run at once means two agents editing the same files,
/// two builds fighting over the same build folder, and commits sweeping up each other's half-done work.
/// So a folder is held by ONE turn at a time; everyone else waits their turn, in order.
///
/// The queue is in-app; a small lock file in cChat's own folder (never inside your projects) makes it
/// hold across BOTH builds of cChat and survive a crash: a lock whose process is gone, or older than
/// the ceiling, is ignored.
@MainActor
final class Traffic {
    static let shared = Traffic()

    struct Ticket {
        let path: String
        let id: UUID
    }

    private struct Waiter {
        let id: UUID
        let label: String
        let resume: CheckedContinuation<Void, Never>
    }

    private var holder: [String: (id: UUID, label: String, since: Date)] = [:]
    private var queue: [String: [Waiter]] = [:]
    private var pollers: [String: Task<Void, Never>] = [:]
    static let staleAfter: TimeInterval = 45 * 60

    /// Who is working in this folder right now (nil = free), for the "waiting for…" line.
    func busyLabel(_ path: String) -> String? { holder[path]?.label ?? lockFileLabel(path) }

    /// Wait for the folder, then take it. Cancelling while waiting gives up the place in line.
    func take(_ path: String, label: String) async -> Ticket? {
        let id = UUID()
        while true {
            if holder[path] == nil && lockFileLabel(path) == nil {
                holder[path] = (id, label, Date())
                writeLockFile(path, label: label)
                return Ticket(path: path, id: id)
            }
            // Someone has it. Get in line and sleep until they hand it over (or a foreign lock clears).
            let left: Bool = await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    queue[path, default: []].append(Waiter(id: id, label: label, resume: cont))
                    startPolling(path)
                }
                return Task.isCancelled
            } onCancel: {
                Task { @MainActor in self.drop(id, from: path) }
            }
            if left || Task.isCancelled { return nil }
        }
    }

    func give(_ ticket: Ticket?) {
        guard let ticket, holder[ticket.path]?.id == ticket.id else { return }
        holder[ticket.path] = nil
        removeLockFile(ticket.path)
        wakeNext(ticket.path)
    }

    private func wakeNext(_ path: String) {
        guard var line = queue[path], !line.isEmpty else { queue[path] = nil; return }
        let next = line.removeFirst()
        queue[path] = line.isEmpty ? nil : line
        next.resume.resume()
    }

    private func drop(_ id: UUID, from path: String) {
        guard var line = queue[path] else { return }
        if let idx = line.firstIndex(where: { $0.id == id }) {
            let w = line.remove(at: idx)
            queue[path] = line.isEmpty ? nil : line
            w.resume.resume()
        }
    }

    /// Only needed while a FOREIGN lock (the other cChat build) holds the folder: nobody will hand it
    /// over in-process, so check every couple of seconds until it clears.
    private func startPolling(_ path: String) {
        guard pollers[path] == nil else { return }
        pollers[path] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if self.holder[path] == nil && self.lockFileLabel(path) == nil {
                    self.wakeNext(path)
                }
                if self.queue[path] == nil { break }
            }
            self?.pollers[path] = nil
        }
    }

    // MARK: The lock file (shared between both builds of cChat)

    private static let dir: URL = {
        let d = Store.fileURL.deletingLastPathComponent().appendingPathComponent("locks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func lockURL(_ path: String) -> URL {
        let safe = path.replacingOccurrences(of: "/", with: "_")
        return Self.dir.appendingPathComponent("\(safe.suffix(120)).json")
    }

    /// A lock from ANOTHER cChat process, if it's still valid. Our own locks and dead ones don't count.
    private func lockFileLabel(_ path: String) -> String? {
        guard let d = try? Data(contentsOf: lockURL(path)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pid = o["pid"] as? Int32, let at = o["at"] as? TimeInterval else { return nil }
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }
        let dead = kill(pid, 0) != 0 && errno == ESRCH
        if dead || Date().timeIntervalSince1970 - at > Self.staleAfter {
            removeLockFile(path)
            return nil
        }
        return (o["label"] as? String) ?? "another cChat"
    }

    private func writeLockFile(_ path: String, label: String) {
        let o: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                "at": Date().timeIntervalSince1970, "label": label]
        try? JSONSerialization.data(withJSONObject: o).write(to: lockURL(path), options: .atomic)
    }

    private func removeLockFile(_ path: String) {
        try? FileManager.default.removeItem(at: lockURL(path))
    }
}
