import SwiftUI

/// The whole header toggles the section; embedded controls keep their own actions.
struct HeaderDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    configuration.isExpanded.toggle()
                } label: {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(configuration.isExpanded ? "Collapse section" : "Expand section")
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
            // A normal tap gesture lets child buttons consume their clicks first.
            // Do not use a simultaneous gesture or wrap the label in a button.
            .onTapGesture { configuration.isExpanded.toggle() }

            if configuration.isExpanded {
                configuration.content
                    // SwiftUI resets disclosure styles inside a styled group's content.
                    .disclosureGroupStyle(HeaderDisclosureGroupStyle())
                    .padding(.leading, 18)
            }
        }
    }
}
