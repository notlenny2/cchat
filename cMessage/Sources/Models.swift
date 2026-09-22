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
}

struct Conversation: Identifiable, Codable, Hashable {
    var id = UUID()
    var participantIds: [UUID]
    var title: String? = nil
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
    var isPinned: Bool { pinned == true }

    var isGroup: Bool { participantIds.count > 1 }
    var lastDate: Date { messages.last?.date ?? .distantPast }
}

struct StoreData: Codable {
    var contacts: [Contact] = []
    var conversations: [Conversation] = []
}

/// The planning team from the user's global instructions, offered as one-tap sub-contact presets.
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
