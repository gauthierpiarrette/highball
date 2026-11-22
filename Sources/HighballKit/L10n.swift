import Foundation

/// One localization layer for the app and its presentation helpers.
public enum L10n {
    public enum Language: String, Sendable { case en, fr, zhHans = "zh-Hans" }

    /// Respect preference order. Unsupported languages fall back to English.
    public static func language(override: String?, preferredLanguages: [String]) -> Language {
        func supported(_ tag: String) -> Language? {
            let parts = tag.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-")
            guard let first = parts.first else { return nil }
            if first == "en" { return .en }
            if first == "fr" { return .fr }
            if first == "zh" {
                if parts.contains("hant") { return nil }
                if parts.contains("hans") { return .zhHans }
                if parts.contains("tw") || parts.contains("hk") || parts.contains("mo") { return nil }
                return .zhHans
            }
            return nil
        }
        if let override, let chosen = supported(override) { return chosen }
        return preferredLanguages.lazy.compactMap(supported).first ?? .en
    }

    public static var currentLanguage: Language {
        language(override: UserDefaults.standard.string(forKey: "HighballLanguage"),
                 preferredLanguages: Locale.preferredLanguages)
    }

    public static func translate(_ english: String, language: Language = currentLanguage) -> String {
        switch language {
        case .en: return english
        case .fr: return fr[english] ?? english
        case .zhHans: return zhHans[english] ?? english
        }
    }

    /// Localize the template before formatting; argument values are never translated.
    public static func format(_ english: String, _ arguments: String...) -> String {
        String(format: translate(english), arguments: arguments)
    }
}
