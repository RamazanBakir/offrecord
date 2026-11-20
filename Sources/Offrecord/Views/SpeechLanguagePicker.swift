import SwiftUI

/// Transcription language menu: automatic detection first, then every language
/// the on-device transcribers support.
struct SpeechLanguagePicker: View {
    let title: String
    @Binding var selection: SpeechLanguage
    @State private var locales: [Locale] = []

    var body: some View {
        Picker(title, selection: $selection) {
            Text(SpeechLanguage.automatic.displayName).tag(SpeechLanguage.automatic)
            Divider()
            // Keeps the current choice visible while the list loads.
            if case .fixed(let identifier) = selection, !locales.contains(where: { $0.identifier == identifier }) {
                Text(selection.displayName).tag(selection)
            }
            ForEach(locales, id: \.identifier) { locale in
                Text(TranscriberModule.displayName(locale)).tag(SpeechLanguage.fixed(locale.identifier))
            }
        }
        .task { locales = await TranscriberModule.availableLocales() }
    }
}
