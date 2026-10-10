import SwiftUI

/// Compact help for a control or an unavailable source.
struct InfoButton: View {
    let title: String
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "info.circle").font(.caption) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Information about " + title).help(title)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(title).font(.headline); Spacer(); Button("Done") { showing = false }.controlSize(.small) }
                    ScrollView { Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 330)
                }.padding(14).frame(width: 390).fixedSize(horizontal: false, vertical: true)
            }
    }
}
