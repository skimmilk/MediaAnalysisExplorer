import SwiftUI
import ExplorerCore

struct CaptionVocabularyView: View {
    @State private var query = "people"
    var body: some View {
        DisclosureGroup("Installed caption vocabulary · \(CaptionVocabulary.installed.count) entries") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Find word or explicit token ID", text: $query).textFieldStyle(.roundedBorder)
                if CaptionVocabulary.installed.isEmpty { Text("Matching installed vocabulary resource unavailable.").foregroundStyle(.secondary) }
                ForEach(CaptionVocabulary.matches(query)) { token in
                    HStack { Text(String(token.id)).monospacedDigit().frame(width: 60, alignment: .leading); Text(token.word).textSelection(.enabled) }.font(.caption)
                }
                InfoButton(title: "Caption vocabulary", text: "Words and token IDs from the caption model. Search shows up to 50 matches.")
            }.padding(.top, 7)
        }.font(.caption)
    }
}
