import Foundation

/// Which cChat this is. the user's own build (CCHAT_PERSONAL) keeps his data folder, name and ~/projects exactly
/// as they always were. The public release keeps its own data folder and asks each person for their name
/// and projects folder the first time it opens.
enum Flavor {
    #if CCHAT_PERSONAL
    static let personal = true
    static let dataFolder = "cMessage"
    #else
    static let personal = false
    static let dataFolder = "cChat"
    #endif
}

/// The person using this copy of cChat. Kept in UserDefaults, so the two builds (different bundle ids)
/// never share it.
enum Prefs {
    private static let d = UserDefaults.standard

    /// What agents call the person they're texting.
    static var userName: String {
        get {
            if let n = d.string(forKey: "userName")?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
            if Flavor.personal { return "the user" }
            #if os(macOS)
            if let first = NSFullUserName().split(separator: " ").first { return String(first) }
            #endif
            return "the user"
        }
        set { d.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "userName") }
    }

    /// Where their projects live. Every folder in here can be texted.
    static var projectsRoot: URL {
        get {
            if let p = d.string(forKey: "projectsRoot"), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "projectsRoot") }
    }

    /// The projects folder the way a person would say it: "~/projects".
    static var projectsRootShort: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = projectsRoot.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    /// The welcome screen has been finished. the user's build never shows it.
    static var setupDone: Bool {
        get { Flavor.personal || d.bool(forKey: "setupDone") }
        set { d.set(newValue, forKey: "setupDone") }
    }
}
