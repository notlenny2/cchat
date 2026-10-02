import Foundation

/// The Water Cooler: once a night, the Futurists and Designers of a few projects meet in one group chat and trade
/// ideas for each other's projects. It keeps going, a round at a time, until it has spent its share of the user's
/// weekly Claude limit (`share`, 10 points of the week bar), then someone wraps up the best ideas for the morning.
///
/// Projects take turns (least recently visited first), so every project gets a seat over a few nights without
/// one night costing more than its share. Spending is measured on the real usage meter, not guessed.
@MainActor
final class WaterCooler {
    static let shared = WaterCooler()

    /// Of the weekly limit (0...1), per night.
    static let share = 0.10
    /// Starts any time in this window (local hours) if it hasn't run today, so it never competes with the day's work.
    static let hours = 1..<6
    static let projectsPerNight = 4
    static let maxRounds = 14
    /// Never start, or keep going, past these.
    static let weekCeiling = 0.85
    static let sessionCeiling = 0.85
    static let title = "Water Cooler"
    static let host = "Water Cooler"

    private weak var store: Store?
    private var run: Task<Void, Never>?
    var isRunning: Bool { run != nil }

    private let d = UserDefaults.standard
    private var lastDay: String? {
        get { d.string(forKey: "coolerLastDay") }
        set { d.set(newValue, forKey: "coolerLastDay") }
    }
    /// project id -> when it last had a seat.
    private var visited: [String: Double] {
        get { d.dictionary(forKey: "coolerVisited") as? [String: Double] ?? [:] }
        set { d.set(newValue, forKey: "coolerVisited") }
    }
    /// On in the owner's build. Off elsewhere until someone asks for it.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "waterCooler") as? Bool ?? Flavor.personal }
        set { UserDefaults.standard.set(newValue, forKey: "waterCooler") }
    }

    private static var today: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    /// Called every minute by the store.
    func tick(_ store: Store) {
        self.store = store
        guard Self.enabled, !Flavor.solo, run == nil, lastDay != Self.today,
              Self.hours.contains(Calendar.current.component(.hour, from: Date())) else { return }
        start(store)
    }

    /// File > Start the Water Cooler Now, or the nightly tick.
    func start(_ store: Store) {
        guard run == nil else { return }
        self.store = store
        lastDay = Self.today
        run = Task { [weak self] in
            await self?.session()
            self?.run = nil
        }
    }

    func stop() {
        run?.cancel()
        if let s = store, let c = s.conversations.first(where: \.isCooler) { s.stop(c.id) }
    }

    // MARK: One night

    private func session() async {
        guard let store else { return }
        // A fresh reading first: the meter only moves when Claude runs, and it may be hours old.
        _ = try? await ClaudeRunner.quick(prompt: "ok", system: "Reply with ok.")
        try? await Task.sleep(for: .seconds(1))
        guard let week = store.usage.claude?.week?.current else {
            Log.error("water cooler: no Claude usage reading, skipped")
            return
        }
        if week >= Self.weekCeiling || (store.usage.claude?.session?.current ?? 0) >= Self.sessionCeiling {
            Log.info("water cooler: plan too full tonight (week \(Int(week * 100))%), skipped")
            return
        }
        let seats = pickProjects(store)
        guard seats.count >= 2 else { Log.info("water cooler: fewer than two projects, skipped"); return }
        let people = seats.flatMap { seat(for: $0, in: store) }
        guard people.count >= 2, let convId = room(with: people, store: store) else { return }
        var seen = visited
        for p in seats { seen[p.id.uuidString] = Date().timeIntervalSince1970 }
        visited = seen

        var start = week
        Log.info("water cooler: started at week \(Int(week * 100))% with \(seats.map(\.name))")
        func spent() -> Double {
            let now = store.usage.claude?.week?.current ?? start
            if now < start { start = 0 }   // the week refilled mid-run
            return now - start
        }
        func full() -> Bool {
            (store.usage.claude?.week?.current ?? 0) >= Self.weekCeiling
                || (store.usage.claude?.session?.current ?? 0) >= Self.sessionCeiling
        }

        let names = people.map(store.displayName)
        var round = 0
        var talked: [UUID: Int] = [:]
        await say(opener(), in: convId, everyone: true, store: store)
        while !Task.isCancelled, round < Self.maxRounds, spent() < Self.share, !full() {
            round += 1
            let pair = pickPair(people, talked: &talked)
            let ask = Self.prompts[(round - 1) % Self.prompts.count]
            await say("@\(store.displayName(pair.0)) and @\(store.displayName(pair.1)): \(ask)", in: convId, store: store)
        }
        guard !Task.isCancelled else { return }
        let closer = people.first { $0.name.localizedCaseInsensitiveContains("futurist") } ?? people[0]
        await say("@\(store.displayName(closer)): that's tonight. Wrap it up for \(Prefs.userName): the three to five best ideas from tonight, each with which project it's for and one line on why. Keep it short.", in: convId, store: store)
        Log.info("water cooler: done, \(round) rounds, spent \(Int((spent() * 100).rounded())) points of the week, \(names.count) people")
    }

    /// Sends as the host and waits for the room to go quiet.
    private func say(_ text: String, in convId: UUID, everyone: Bool = false, store: Store) async {
        store.send(text, in: convId, from: Self.host, everyone: everyone)
        while store.isBusy(convId), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func opener() -> String {
        "Evening, everyone. This is the Water Cooler: Futurists and Designers from a few of \(Prefs.userName)'s projects, "
            + "here to swap ideas. Say in a line or two what your project is and the most interesting thing going on in it "
            + "right now, then toss one idea at another project here."
    }

    static let prompts = [
        "pick the best idea so far that isn't for your own project and make it sharper or more concrete.",
        "steal something. What from another project here would you bring home, and what would it look like in yours?",
        "push back on an idea above that you think wouldn't work, and offer a better one.",
        "what's something none of these projects do yet that people would love?",
        "take an idea from tonight and say the smallest first version of it someone could build this week.",
        "what's a feeling or moment in another project here that you wish yours had?",
        "find two ideas from tonight that would be better together and combine them.",
    ]

    /// The two who've had the fewest turns, from different projects, so everyone gets heard.
    private func pickPair(_ people: [Contact], talked: inout [UUID: Int]) -> (Contact, Contact) {
        let order = people.enumerated()
            .sorted { (talked[$0.element.id] ?? 0, $0.offset) < (talked[$1.element.id] ?? 0, $1.offset) }.map(\.element)
        let a = order[0]
        let b = order.dropFirst().first { $0.parentId != a.parentId } ?? order[1]
        talked[a.id, default: 0] += 1
        talked[b.id, default: 0] += 1
        return (a, b)
    }

    // MARK: Who comes

    /// Real project folders only (not the home folder), least recently seated first, then most recently active.
    private func pickProjects(_ store: Store) -> [Contact] {
        let home = Prefs.home.standardizedFileURL.path
        let seen = visited
        let fm = FileManager.default
        func active(_ p: Contact) -> Date {
            store.conversations.filter { c in c.participantIds.contains { store.projectOf($0)?.id == p.id } }
                .map(\.lastDate).max() ?? .distantPast
        }
        return store.projects
            .filter { p in
                let path = URL(fileURLWithPath: p.projectPath).standardizedFileURL.path
                return path != home && path != "/" && fm.fileExists(atPath: path)
            }
            .sorted { a, b in
                let va = seen[a.id.uuidString] ?? 0, vb = seen[b.id.uuidString] ?? 0
                return va != vb ? va < vb : active(a) > active(b)
            }
            .prefix(Self.projectsPerNight).map { $0 }
    }

    /// The project's Futurist and Designer, made from the user's team (or the classic one) if they aren't there yet.
    private func seat(for project: Contact, in store: Store) -> [Contact] {
        ["Futurist", "Designer"].compactMap { name in
            let member = store.team.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                ?? TeamMember.classic.first { $0.name == name }
            let existing = store.subContacts(of: project.id).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let existing { return existing }
            guard let member else { return nil }
            return store.addSubContact(to: project, name: name, role: member.role)
        }
    }

    /// The one Water Cooler chat, with tonight's people in it. Their memory of earlier nights stays with the chat.
    private func room(with people: [Contact], store: Store) -> UUID? {
        let ids = people.map(\.id)
        if let i = store.conversations.firstIndex(where: \.isCooler) {
            let before = store.conversations[i].participantIds
            store.conversations[i].participantIds = ids
            store.conversations[i].hidden = false
            store.conversations[i].pending = []
            let came = people.filter { !before.contains($0.id) }.map(store.displayName)
            let left = before.filter { !ids.contains($0) }.compactMap { store.contact($0) }.map(store.displayName)
            for n in left { store.conversations[i].messages.append(Message(senderId: nil, text: "\(n) left the group.", kind: .system)) }
            for n in came { store.conversations[i].messages.append(Message(senderId: nil, text: "\(n) joined the group.", kind: .system)) }
            store.save()
            return store.conversations[i].id
        }
        var c = Conversation(participantIds: ids, title: Self.title)
        c.cooler = true
        // The host drives the rounds; left to themselves they'd stop after one.
        c.chatter = false
        c.pinned = true
        c.folder = ChatFolders.other
        store.conversations.append(c)
        store.save()
        return c.id
    }
}
