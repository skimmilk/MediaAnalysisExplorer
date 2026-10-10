import SwiftUI
import Charts
import ExplorerCore

struct DescriptorVectorView: View {
    let payload: DecodedPayload
    let column: String
    let peers: [DBRow]
    @State private var comparison = ""
    private var matches: [DBRow] { peers.filter { $0.decoded[column].flatMap { DescriptorPayload.cosine(payload, $0) } != nil } }
    var body: some View {
        DisclosureGroup("Descriptor components · \(payload.vector.count)") {
            VStack(alignment: .leading, spacing: 8) {
                Chart(Array(payload.vector.enumerated()), id: \.offset) { component in
                    BarMark(x: .value("Component index", component.offset), y: .value("Stored component", component.element)).foregroundStyle(.teal)
                }.frame(height: 135).chartXAxisLabel("Component index")
                if matches.count > 1 {
                    Picker("Compare loaded record", selection: $comparison) {
                        Text("Select record…").tag("")
                        ForEach(matches) { row in Text("Record " + row["Z_PK"]).tag(row["Z_PK"]) }
                    }.controlSize(.small)
                    if let row = matches.first(where: { $0["Z_PK"] == comparison }), let other = row.decoded[column], let score = DescriptorPayload.cosine(payload, other) {
                        Text(String(format: "Cosine similarity: %.6f", score)).font(.caption.monospacedDigit())
                    }
                }
                InfoButton(title: "Descriptor comparison", text: "Compare feature vectors with matching formats. Higher similarity means their numeric features are more alike.")
            }.padding(.top, 5)
        }.font(.caption)
    }
}
