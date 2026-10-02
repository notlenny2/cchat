import Foundation

/// A person you can text. A top-level contact is a project; a sub-contact lives under a project
/// (same folder) but carries its own persona and its own memory (Claude session).
struct Contact: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var projectPath: String
    var parentId: UUID? = nil
    /// Who this agent is, in plain English ("the UX designer for Website"). Empty for a plain project contact.
    var role: String = ""
    /// "" = the CLI default, otherwise an alias like "opus", "sonnet", "haiku".
    var model: String = ""
    /// When on, the agent can run any tool without asking (bypassPermissions). Off = edits only.
    var fullAccess: Bool = false
    var colorIndex: Int = 0
    /// Set when this contact was imported from a NodeTerm chat, so re-importing doesn't duplicate it.
    var nodeTermId: String? = nil
    /// Contact photo: the project's app icon (found automatically) or a picture the user chose.
    var iconPath: String? = nil
    var iconSearched: Bool? = nil
    /// Answers last in a group and pulls the others together (a team member marked "gets the final word").
    var lastWord: Bool? = nil

    var isSubContact: Bool { parentId != nil }
    var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

struct Message: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case normal, error, system }
    var id = UUID()
    /// nil = the user.
    var senderId: UUID?
    var text: String
    var date = Date()
    var kind: Kind = .normal
    /// Pictures the user dragged in, stored as files in cMessage's own attachments folder.
    var attachments: [String]? = nil
    /// Set when another agent sent this on the user's behalf, not the user. senderId is nil.
    var from: String? = nil
    /// What the agent did on its way to this reply (tools it ran, their output), for View > Show the Work.
    var work: [WorkStep]? = nil
    var isFromUser: Bool { senderId == nil && from == nil }
}

/// One thing an agent did during a turn, terminal style: a tool it ran (and what came back), or a thought.
struct WorkStep: Codable, Hashable, Identifiable {
    /// `info` = the bookkeeping lines Claude Code's verbose mode prints: session start, hooks, the end-of-turn tally.
    enum Kind: String, Codable { case tool, output, note, thinking, info }
    var id = UUID()
    var kind: Kind
    /// Tool name for `.tool` ("Bash", "Read"...), empty otherwise.
    var title: String = ""
    var text: String
    var failed: Bool? = nil
    /// Ties a tool's output to the call it came from (Claude can run several at once).
    var ref: String? = nil
    /// Done by a helper agent the main one sent off (Task/Agent), shown indented under it.
    var sub: Bool? = nil

    /// Keeps store.json from ballooning: a long command output only needs its start and end.
    static func clip(_ s: String, _ max: Int = 5000) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return "\(t.prefix(max * 2 / 3))\n…\n\(t.suffix(max / 3))"
    }
    static let maxPerTurn = 300
}

/// Which AI runs the agents in a chat. Picked when the chat starts.
enum Engine: String, Codable, CaseIterable, Identifiable {
    case claude, codex, gemini, grok
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        }
    }
    /// An engine this build doesn't know yet (a newer Mac talking to an older phone) reads as Claude
    /// instead of breaking the whole snapshot.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Engine(rawValue: raw) ?? .claude
    }
}

struct ModelOption: Codable, Hashable, Identifiable {
    var id: String      // "" = default
    var label: String
    var note: String
}

enum ModelCatalog {
    /// What a Claude chat on "Default" runs: the alias, so it moves to each new Opus by itself.
    static let claudeDefault = "opus"
    static let claude: [ModelOption] = [
        ModelOption(id: "", label: "Default", note: "The newest Opus"),
        ModelOption(id: "fable", label: "Fable", note: "Most capable"),
        ModelOption(id: "opus", label: "Opus", note: "Very capable"),
        ModelOption(id: "sonnet", label: "Sonnet", note: "Fast and smart"),
        ModelOption(id: "haiku", label: "Haiku", note: "Quickest, cheapest"),
    ]
    /// Gemini CLI's own aliases (`-m auto|pro|flash|flash-lite`), so this list doesn't go stale with each release.
    static let gemini: [ModelOption] = [
        ModelOption(id: "", label: "Default", note: "Gemini picks per request (auto)"),
        ModelOption(id: "pro", label: "Pro", note: "Most capable"),
        ModelOption(id: "flash", label: "Flash", note: "Fast and smart"),
        ModelOption(id: "flash-lite", label: "Flash-Lite", note: "Quickest, cheapest"),
    ]
    static func label(_ id: String?, in list: [ModelOption]) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return list.first { $0.id == id }?.label ?? id
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    var id = UUID()
    var participantIds: [UUID]
    var title: String? = nil
    /// nil = Claude (every chat made before Codex existed).
    var engine: Engine? = nil
    var usesCodex: Bool { engine == .codex }
    var usesGemini: Bool { engine == .gemini }
    var usesGrok: Bool { engine == .grok }
    /// Claude Code is the one engine with real sessions to fork/condense; the others keep their own threads.
    var isClaude: Bool { (engine ?? .claude) == .claude }
    /// Model picked for this chat. nil = the contact's setting (Claude) or Codex's own default.
    var model: String? = nil
    /// In a group: after answering the user, let the agents carry on with each other for a few turns.
    /// nil = on (the point of a group chat); false = they only ever answer the user.
    var chatter: Bool? = nil
    var letThemTalk: Bool { chatter ?? true }
    /// Group photo the user dragged onto the chat header (copied into cMessage's photos folder).
    var photoPath: String? = nil
    var messages: [Message] = []
    /// contactId.uuidString -> Claude session id. Each chat keeps its own sessions, so a group
    /// chat never leaks into that agent's 1:1 thread and vice versa.
    var sessions: [String: String] = [:]
    /// contactId.uuidString -> number of messages that agent has already been shown.
    var seenCount: [String: Int] = [:]
    /// Agents still owed a turn, in order.
    var pending: [UUID] = []
    var suggestions: [String] = []
    var unread = false
    /// Hidden chats keep their memory; opening the contact again brings them back.
    var hidden = false
    /// Contacts whose next turn must fork their session instead of continuing it. Used for chats
    /// imported from NodeTerm: the terminal may still be using that session, so cMessage branches
    /// off a copy with the full memory rather than writing into the same one.
    var forkNext: [String]? = nil
    /// Pinned chats sit in the big-avatar row at the top of the sidebar, like iMessage.
    var pinned: Bool? = nil
    /// Set when the user texts a group without naming anyone: before anyone answers, a quick call
    /// picks the agent (or agents) best suited to the message.
    var routeNext: Bool? = nil
    var isPinned: Bool { pinned == true }
    /// An agent here is stuck until the user answers (a decision, an OK, a login, a permission).
    /// Set from a `<<needs you: why>>` line or a blocked tool; cleared as soon as the user texts this chat.
    var needsYou: String? = nil
    /// Which project folder of the chat list this chat is filed under (a project contact's id, or
    /// `ChatFolders.other`). nil = its own project, worked out from its first member. Only tidies the list;
    /// the agents keep working in their own project folders.
    var folder: String? = nil
    /// The Water Cooler: a nightly group where projects' Futurists and Designers trade ideas (see WaterCooler).
    /// Talk only; nobody in it touches files or buzzes the user's phone.
    var cooler: Bool? = nil
    var isCooler: Bool { cooler == true }

    var isGroup: Bool { participantIds.count > 1 }
    var lastDate: Date { messages.last?.date ?? .distantPast }
}

/// The chat list sorted into project folders (Mac and phone). Each chat sits under the project of its first
/// member unless it was dragged into another folder; chats with no real project go under "Other chats".
enum ChatFolders {
    static let other = "other"

    struct Folder: Identifiable {
        let id: String
        let name: String
        /// The project contact the heading shows the picture of. nil for "Other chats".
        let project: UUID?
        var convs: [Conversation]
    }

    /// `project` maps a contact to its top-level project (id + name), or nil when it has no project folder.
    /// Folders come newest first, "Other chats" last; chats keep the order they came in.
    static func sort(_ convs: [Conversation], project: (UUID) -> (id: UUID, name: String)?) -> [Folder] {
        var folders: [String: Folder] = [:], order: [String] = []
        func add(_ key: String, _ name: String, _ pid: UUID?, _ c: Conversation) {
            if folders[key] == nil { folders[key] = Folder(id: key, name: name, project: pid, convs: []); order.append(key) }
            folders[key]?.convs.append(c)
        }
        for c in convs {
            if let f = c.folder, f == other { add(other, "Other chats", nil, c); continue }
            if let f = c.folder, let id = UUID(uuidString: f), let p = project(id), p.id == id { add(f, p.name, id, c); continue }
            if let first = c.participantIds.first, let p = project(first) { add(p.id.uuidString, p.name, p.id, c) }
            else { add(other, "Other chats", nil, c) }
        }
        let newest = { (f: Folder) in f.convs.map(\.lastDate).max() ?? .distantPast }
        return order.compactMap { folders[$0] }.sorted { a, b in
            if (a.id == other) != (b.id == other) { return b.id == other }
            return newest(a) > newest(b)
        }
    }

    /// Folded headings, kept per device as one comma-separated string.
    static func folded(_ s: String) -> Set<String> { Set(s.split(separator: ",").map(String.init)) }
    static func toggle(_ id: String, in s: String) -> String {
        var set = folded(s)
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        return set.sorted().joined(separator: ",")
    }
}

struct StoreData: Codable {
    var contacts: [Contact] = []
    var conversations: [Conversation] = []
    /// The user's own team from "Build my team". nil = the classic seven.
    var team: [TeamMember]? = nil
}

/// One seat on the user's team: who they are, what they care about, what they're like.
/// Called in on a project, each becomes a sub-contact whose role is `role`.
struct TeamMember: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// What they care about / their job in the room.
    var job: String = ""
    /// How they come across: tone, temperament, quirks.
    var personality: String = ""
    /// Answers after everyone else in a group and pulls it together (like the Director).
    var lastWord: Bool = false

    var role: String {
        var s = name.lowercased().hasPrefix("the ") ? "\(name)." : "The \(name)."
        let j = job.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        if !j.isEmpty { s += " " + j + (j.hasSuffix(".") ? "" : ".") }
        if !p.isEmpty { s += " Personality: " + p + (p.hasSuffix(".") ? "" : ".") }
        if lastWord { s += " In a group you speak last: weigh what the others said and give one clear recommendation." }
        return s
    }

    var isBlank: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The classic seven, split into job and personality so they can be edited as a starting point.
    static let classic: [TeamMember] = [
        TeamMember(name: "Director", job: "Oversees everyone, weighs the strong options against each other and gives advice on next steps. Has shipped major apps at scale and wants this one to succeed at scale.",
                   personality: "Patient and calculating, patient with an amateur.", lastWord: true),
        TeamMember(name: "Designer", job: "The UX person. Why are you opening the app, what excites you, how easy is it to use and look at? Less concerned with what it does.",
                   personality: "Wants software to be a pleasure to use. Thinks like an Italian supercar."),
        TeamMember(name: "Optimizer", job: "Efficiency. Hates extra code that goes nowhere and redundancy, wants the app fast and sensible.",
                   personality: "Lean and mean, keeps the Designer and Engineer from getting too crazy."),
        TeamMember(name: "Engineer", job: "Does it WORK? Makes features work as well as possible without much thought for optimization or UI.",
                   personality: "UX be damned, built like a Rolls Royce."),
        TeamMember(name: "Salesman", job: "How can this make money ethically? Premium tiers, unlockables, drops, sponsorships, subscriptions.",
                   personality: "Not above selling for a dollar."),
        TeamMember(name: "Marketer", job: "How does this generate buzz and get widely adopted? Campaigns, viral angles, community.",
                   personality: "Thinks in launch events and livestreams."),
        TeamMember(name: "Futurist", job: "Always has a new feature, tuned into what's newly possible and what's never been done. Pushes the project in new directions.",
                   personality: "Excitable dreamer. If it were a car, it would fly."),
    ]
}

extension Array where Element == Message {
    /// A run of "X joined the group." (or "left the group.") notes shows as one line
    /// ("A, B and 3 others joined the group."). Display only: the stored chat keeps every note.
    var squishedJoins: [Message] {
        self.squished(" joined the group.").squished(" left the group.")
    }

    private func squished(_ tail: String) -> [Message] {
        var out: [Message] = []
        var names: [String] = []
        var first: Message?
        func flush() {
            guard var m = first else { return }
            switch names.count {
            case 1: m.text = "\(names[0])\(tail)"
            case 2: m.text = "\(names[0]) and \(names[1])\(tail)"
            case 3: m.text = "\(names[0]), \(names[1]) and \(names[2])\(tail)"
            default: m.text = "\(names[0]), \(names[1]) and \(names.count - 2) others\(tail)"
            }
            out.append(m); names = []; first = nil
        }
        for m in self {
            if m.kind == .system, m.text.hasSuffix(tail) {
                if first == nil { first = m }
                names.append(String(m.text.dropLast(tail.count)))
            } else {
                flush(); out.append(m)
            }
        }
        flush()
        return out
    }
}
