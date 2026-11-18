import Foundation
import Observation

/// Interface language. English is the default; the user can switch in Settings.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    /// Written in its own language so it is recognisable whatever the current UI language is.
    var nativeName: String {
        switch self {
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    /// Locale used for dates and numbers shown in the interface.
    var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en_US")
        case .turkish: Locale(identifier: "tr_TR")
        }
    }

    /// Translation table for this language; English strings are the keys.
    fileprivate var table: [String: String]? {
        switch self {
        case .english: nil
        case .turkish: Translations.turkish
        }
    }

    static var current: AppLanguage { Localizer.shared.language }
}

/// Holds the selected language. SwiftUI views that call `L(_:)` read `language`
/// and therefore re-render immediately when it changes.
@Observable
final class Localizer: @unchecked Sendable {
    static let shared = Localizer()
    static let defaultsKey = "appLanguage"

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            applyToSystemComponents()
            NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
        }
    }

    private init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .english
    }

    /// Standard menus, permission prompts and other system-provided text follow the
    /// app's preferred localization; call before the app starts so they match.
    func applyToSystemComponents() {
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}

extension Notification.Name {
    static let appLanguageChanged = Notification.Name("appLanguageChanged")
}

/// Returns `english` translated into the current interface language.
func L(_ english: String) -> String {
    AppLanguage.current.table?[english] ?? english
}

/// Translates `english`, then fills each `%@` in order with `arguments`.
func L(_ english: String, _ arguments: Any...) -> String {
    var result = L(english)
    var searchStart = result.startIndex
    for argument in arguments {
        guard let range = result.range(of: "%@", range: searchStart..<result.endIndex) else { break }
        let value = String(describing: argument)
        result.replaceSubrange(range, with: value)
        searchStart = result.index(range.lowerBound, offsetBy: value.count)
    }
    return result
}
