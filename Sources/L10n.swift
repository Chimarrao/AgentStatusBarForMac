import Foundation

/// UI languages. English is the default and the key of every string.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, pt, es, zh, hi, fr, ru, ja, de, id

    var id: String { rawValue }

    /// Shown in the language picker, always in the language itself.
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .pt: return "Português"
        case .es: return "Español"
        case .zh: return "中文"
        case .hi: return "हिन्दी"
        case .fr: return "Français"
        case .ru: return "Русский"
        case .ja: return "日本語"
        case .de: return "Deutsch"
        case .id: return "Bahasa Indonesia"
        }
    }

    var locale: Locale {
        Locale(identifier: self == .zh ? "zh-Hans" : rawValue)
    }
}

enum L10n {
    /// Set on the main actor when the user picks a language; read from anywhere.
    nonisolated(unsafe) static var language: AppLanguage = .en
}

/// Translates an English UI string. Unknown strings (and English) come back unchanged.
/// Templates use `%@` / `%d` (or positional `%1$@`) and `%%` for a literal percent sign.
func tr(_ key: String, _ args: CVarArg...) -> String {
    let template = Translations.table(for: L10n.language)[key] ?? key
    guard !args.isEmpty else { return template }
    return String(format: template, locale: L10n.language.locale, arguments: args)
}
