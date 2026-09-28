import Foundation
import Security

/// Optional API keys, one per engine, for people who'd rather pay per use than sign in with a plan.
/// Kept in the login Keychain (this Mac only, readable while unlocked), never in store.json, never logged,
/// never sent to the phone. A turn hands the key to that engine's command-line tool as the environment
/// variable it already understands, so cChat itself never talks to any AI company's servers.
enum APIKeys {
    private static let service = "cChat API keys"

    /// The variable each tool reads its key from.
    static func envNames(_ e: Engine) -> [String] {
        switch e {
        case .claude: return ["ANTHROPIC_API_KEY"]
        case .codex: return ["OPENAI_API_KEY", "CODEX_API_KEY"]
        case .gemini: return ["GEMINI_API_KEY"]
        case .grok: return ["XAI_API_KEY"]
        }
    }

    /// Where to get one, for the Settings link.
    static func consoleURL(_ e: Engine) -> URL {
        switch e {
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .codex: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .grok: return URL(string: "https://console.x.ai")!
        }
    }

    static func get(_ e: Engine) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: e.rawValue, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func has(_ e: Engine) -> Bool { get(e) != nil }

    @discardableResult
    static func set(_ key: String?, for e: Engine) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: e.rawValue]
        SecItemDelete(base as CFDictionary)
        let k = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { Log.info("api key removed for \(e.rawValue)"); return true }
        var add = base
        add[kSecValueData as String] = Data(k.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        Log.info("api key \(ok ? "saved" : "NOT saved") for \(e.rawValue)")   // never the key itself
        return ok
    }

    /// Puts the saved key (if any) into a child process's environment.
    static func apply(_ e: Engine, to env: inout [String: String]) {
        guard let k = get(e) else { return }
        for n in envNames(e) { env[n] = k }
    }
}
