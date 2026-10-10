import SwiftUI
import ExplorerCore

struct PersistenceHistoryView: View {
    let history: PersistenceHistory
    var body: some View {
        if !history.events.isEmpty || !history.modelFields.isEmpty || !history.issues.isEmpty {
            DisclosureGroup("Result write history & schema") {
                VStack(alignment: .leading, spacing: 10) {
                    InfoButton(title: "Result write history", text: "When analysis results were saved or changed in the library.")
                    ForEach(history.events) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                if let date = event.date { Text(date.formatted(date: .abbreviated, time: .standard)).font(.caption.monospacedDigit()) }
                                else { Text("Timestamp unavailable").font(.caption) }
                                Spacer(); Text("\(event.changes) retained changes").font(.caption2)
                            }
                            Text("\(event.bundle == "NULL" ? "Bundle unavailable" : event.bundle) · \(event.process == "NULL" ? "Process unavailable" : event.process) · transaction \(event.id)").font(.caption2).foregroundStyle(.secondary)
                            Text(event.entities).font(.caption2).lineLimit(2).help(event.entities)
                            Text("Raw change codes: " + event.types).font(.caption2).foregroundStyle(.secondary)
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.2))
                    }
                    if history.events.count == 50 { Text("Latest 50 linked transactions shown.").font(.caption2).foregroundStyle(.secondary) }
                    MetadataFields(fields: history.modelFields)
                    ForEach(history.issues, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
                }.padding(.top, 8)
            }.font(.caption)
        }
    }
}
