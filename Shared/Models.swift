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
    enum Kind: String, Codable { case tool, output, note, thinking }
    var id = UUID()
    var kind: Kind
    /// Tool name for `.tool` ("Bash", "Read"...), empty otherwise.
    var title: String = ""
    var text: String
    var failed: Bool? = nil
    /// Ties a tool's output to the call it came from (Claude can run several at once).
    var ref: String? = nil

    /// Keeps store.json from ballooning: a long command output only needs its start and end.
    static func clip(_ s: String, _ max: Int = 1500) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return "\(t.prefix(max * 2 / 3))\n…\n\(t.suffix(max / 3))"
    }
    static let maxPerTurn = 300
}

/// Which AI runs the agents in a chat. Picked when the chat starts.
enum Engine: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var label: String { self == .claude ? "Claude" : "Codex" }
}

struct ModelOption: Codable, Hashable, Identifiable {
    var id: String      // "" = default
    var label: String
    var note: String
}

enum ModelCatalog {
    static let claude: [ModelOption] = [
        ModelOption(id: "", label: "Default", note: "Whatever Claude Code normally uses"),
        ModelOption(id: "fable", label: "Fable", note: "Most capable"),
        ModelOption(id: "opus", label: "Opus", note: "Very capable"),
        ModelOption(id: "sonnet", label: "Sonnet", note: "Fast and smart"),
        ModelOption(id: "haiku", label: "Haiku", note: "Quickest, cheapest"),
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

    var isGroup: Bool { participantIds.count > 1 }
    var lastDate: Date { messages.last?.date ?? .distantPast }
}

struct StoreData: Codable {
    var contacts: [Contact] = []
    var conversations: [Conversation] = []
}

/// The planning team from the author's planning personas, offered as one-tap sub-contact presets.
enum TeamPreset: String, CaseIterable, Identifiable {
    case director, designer, optimizer, engineer, salesman, marketer, futurist
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var role: String {
        switch self {
        case .director: return "The Director. Patient and calculating, weighs the strong options against each other and gives advice on next steps. Has shipped major apps at scale, patient with an amateur, wants the app to succeed at scale."
        case .designer: return "The Designer. The UX person. Why are you opening the app, what excites you, how easy is it to use and look at? Wants software to be a pleasure to use; less concerned with what it does."
        case .optimizer: return "The Optimizer. Lean and mean, hates extra code that goes nowhere and redundancy. Wants the app fast and sensible, keeps the Designer and Engineer from getting too crazy."
        case .engineer: return "The Engineer. UX be damned, does it WORK? Makes features work as well as possible without much thought for optimization or UI."
        case .salesman: return "The Salesman. How can this make money ethically? Premium tiers, unlockables, drops, sponsorships, subscriptions."
        case .marketer: return "The Marketer. How does this generate buzz and get widely adopted? Campaigns, viral angles, community."
        case .futurist: return "The Futurist. Always has a new feature, tuned into what's newly possible and what's never been done. Pushes the project in exciting new directions."
        }
    }
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
