import Foundation

/// The transcription language setting: automatic detection, or one fixed language.
enum SpeechLanguage: Hashable, Sendable {
    case automatic
    /// A locale identifier as listed by the transcribers, e.g. "tr_TR".
    case fixed(String)

    static let automaticIdentifier = "auto"
    private static let english = "en_US"

    init(identifier: String) {
        self = identifier == Self.automaticIdentifier ? .automatic : .fixed(identifier)
    }

    var identifier: String {
        switch self {
        case .automatic: Self.automaticIdentifier
        case .fixed(let identifier): identifier
        }
    }

    /// Languages a recording may be in. Automatic detection chooses between the
    /// system language and English (just one when they are the same language).
    var candidates: [Locale] {
        switch self {
        case .fixed(let identifier):
            return [Locale(identifier: identifier)]
        case .automatic:
            let system = Locale(identifier: SettingsKeys.defaultSpeechLocale)
            let english = Locale(identifier: Self.english)
            return system.language.languageCode == english.language.languageCode ? [system] : [system, english]
        }
    }

    var displayName: String {
        switch self {
        case .automatic:
            let names = candidates.map { AppLanguage.current.locale.localizedString(forLanguageCode: $0.language.languageCode?.identifier ?? "") ?? $0.identifier }
            return L("Automatic (%@)", names.joined(separator: " / "))
        case .fixed(let identifier):
            return TranscriberModule.displayName(Locale(identifier: identifier))
        }
    }

    // MARK: Setting

    private static let migratedKey = "speechLanguageMigratedToAutomatic"

    /// The saved choice; automatic when nothing was chosen.
    static var saved: SpeechLanguage {
        get { SpeechLanguage(identifier: UserDefaults.standard.string(forKey: SettingsKeys.localeIdentifier) ?? automaticIdentifier) }
        set { UserDefaults.standard.set(newValue.identifier, forKey: SettingsKeys.localeIdentifier) }
    }

    /// Before automatic detection existed the setting held the system language by
    /// default; switch those users to automatic once. A different explicit choice is kept.
    static func migrateDefaultChoice() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        guard let stored = defaults.string(forKey: SettingsKeys.localeIdentifier), stored != automaticIdentifier else { return }
        let system = Locale(identifier: SettingsKeys.defaultSpeechLocale).language.languageCode
        if Locale(identifier: stored).language.languageCode == system {
            saved = .automatic
        }
    }
}

/// How confidently one language's model transcribed the speech so far: the
/// model's own word confidence, weighted by length. A model fed speech in another
/// language scores far lower (about 0.1 against 0.9 in tests with Turkish and English).
struct LanguageScore: Sendable {
    /// Text needed before a language can win without a deadline.
    static let minimumCharacters = 40
    /// Lead in mean confidence that counts as a clear win.
    static let margin = 0.3
    /// Confidence a language needs to win early (wrong languages score about 0.1).
    static let minimumConfidence = 0.5

    private(set) var characters = 0
    private var weightedConfidence = 0.0

    var meanConfidence: Double {
        characters > 0 ? weightedConfidence / Double(characters) : 0
    }

    mutating func add(_ chunk: TranscriptionChunk) {
        guard chunk.isFinal, let confidence = chunk.confidence, chunk.scoredCharacters > 0 else { return }
        weightedConfidence += confidence * Double(chunk.scoredCharacters)
        characters += chunk.scoredCharacters
    }

    mutating func merge(_ other: LanguageScore) {
        weightedConfidence += other.weightedConfidence
        characters += other.characters
    }

    /// Index of the clear winner, or nil if it is too early to tell: every language
    /// must have produced text, since models deliver results at different speeds.
    /// With `force` the best so far wins (the first candidate on a tie or without speech).
    static func winner(of scores: [LanguageScore], force: Bool) -> Int? {
        guard var best = scores.indices.first else { return nil }
        for index in scores.indices where scores[index].meanConfidence > scores[best].meanConfidence {
            best = index
        }
        if force { return best }
        guard scores[best].characters >= minimumCharacters, scores[best].meanConfidence >= minimumConfidence,
              scores.allSatisfy({ $0.characters > 0 })
        else { return nil }
        let runnerUp = scores.indices.filter { $0 != best }.map { scores[$0].meanConfidence }.max() ?? 0
        return scores[best].meanConfidence - runnerUp >= margin ? best : nil
    }
}
