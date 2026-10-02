import Foundation

/// Which cChat this is. A personal build (CCHAT_PERSONAL, defined only in a local personal.yml) keeps the
/// original "cMessage" data folder and skips the welcome screen. The normal build uses its own data folder and
/// asks each person for their name and projects folder the first time it opens.
enum Flavor {
    #if CCHAT_PERSONAL
    static let personal = true
    static let dataFolder = "cMessage"
    #elseif CCHAT_SOLO
    static let personal = false
    static let dataFolder = Solo.dataFolder
    #else
    static let personal = false
    static let dataFolder = "cChat"
    #endif

    /// A one-contact build (CCHAT_SOLO): the whole app is a single chat with one agent locked to one folder.
    /// Its name, folder and look come from a `Solo` file that only that build compiles (kept outside git).
    #if CCHAT_SOLO
    static let solo = true
    static let appName = Solo.appName
    #else
    static let solo = false
    static let appName = "cChat"
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
            #if CCHAT_SOLO
            return Solo.userName
            #endif
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
            return Self.home.appendingPathComponent("projects", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "projectsRoot") }
    }

    /// The Mac's home folder. On iPhone/iPad there are no project folders at all (the Mac holds them),
    /// so this is only ever a placeholder there.
    static var home: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    /// The projects folder the way a person would say it: "~/projects".
    static var projectsRootShort: String {
        let home = Self.home.path
        let p = projectsRoot.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    /// iPhone/iPad linking is switched on (the default). Off = the Mac doesn't listen on the network at all.
    static var phoneLink: Bool {
        get { d.object(forKey: "phoneLink") as? Bool ?? true }
        set { d.set(newValue, forKey: "phoneLink") }
    }

    /// Reach this Mac from anywhere through the cChat relay (on by default when linking is on and a relay exists).
    static var awayFromHome: Bool {
        get { d.object(forKey: "awayFromHome") as? Bool ?? true }
        set { d.set(newValue, forKey: "awayFromHome") }
    }

    /// Buzz linked iPhones and iPads when an agent answers and cChat isn't open on them.
    static var phoneNotify: Bool {
        get { d.object(forKey: "phoneNotify") as? Bool ?? true }
        set { d.set(newValue, forKey: "phoneNotify") }
    }

    /// The welcome screen has been finished. A personal build never shows it.
    static var setupDone: Bool {
        get { Flavor.personal || Flavor.solo || d.bool(forKey: "setupDone") }
        set { d.set(newValue, forKey: "setupDone") }
    }
}
