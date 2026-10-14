import SwiftUI
import AVFoundation
import Charts
import ExplorerCore

struct ImageAppearanceFamilyView: View {
    let family: ResultFamily
    let player: AVPlayer?
    let loading: Bool
    let loadMore: () -> Void
    @State private var selection: String?
    private var samples: [DBRow] { ImageFeatureSamples.ordered(family.rows) }
    private var selected: DBRow? { samples.first { $0.referenceID == selection } ?? samples.first }

    init(family: ResultFamily, player: AVPlayer?, loading: Bool, loadMore: @escaping () -> Void, initialSelection: String? = nil) {
        self.family = family; self.player = player; self.loading = loading; self.loadMore = loadMore
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Colors & texture").font(.subheadline.weight(.semibold))
                    InfoButton(title: "Colors & texture", text: ImageFeatureDescriptor.explanation)
                    Spacer()
                    if family.count > 1 { Text("\(family.count) samples").font(.caption2).foregroundStyle(.secondary) }
                }
                if samples.count > 1 {
                    Picker("Analyzed sample", selection: Binding(get: { selected?.referenceID ?? "" }, set: { selection = $0 })) {
                        ForEach(samples) { row in
                            Text(ImageFeatureSamples.time(row).map { "At " + ImageFeatureSamples.timeLabel($0) } ?? "Untimed sample \(row.referenceID)").tag(row.referenceID)
                        }
                    }.controlSize(.small).accessibilityIdentifier("appearance-sample-picker")
                }
                if let selected {
                    ImageAppearanceRecordView(row: selected, player: player).id(selected["ZASSET"] + ":" + selected.referenceID)
                } else {
                    Text("No sample loaded.").font(.caption).foregroundStyle(.secondary)
                }
                if family.rows.count < family.count {
                    HStack {
                        Text("\(family.rows.count) of \(family.count) samples loaded").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button(loading ? "Loading…" : "Load more", action: loadMore).disabled(loading).controlSize(.mini)
                    }
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Reused in the family card and linked-record inspector; raw data remains
/// available even when the layout/checksum or histogram cannot be summarized.
struct ImageAppearanceRecordView: View {
    let row: DBRow
    var player: AVPlayer? = nil
    @State private var technicalDetails = false
    private var payload: DecodedPayload? { row.decoded["ZFEATUREVECTOR"] }

    init(row: DBRow, player: AVPlayer? = nil, initiallyExpanded: Bool = false) {
        self.row = row; self.player = player
        _technicalDetails = State(initialValue: initiallyExpanded)
    }

    func jumpToFrame() {
        guard ImageFeatureSamples.time(row) != nil, let player,
              let value = Int64(row["ZSTARTTIMEVALUE"]), let scale = Int32(row["ZSTARTTIMESCALE"]), scale > 0 else { return }
        player.seek(to: CMTime(value: value, timescale: scale), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let start = ImageFeatureSamples.time(row) {
                HStack {
                    Text("Sample at " + ImageFeatureSamples.timeLabel(start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("appearance-sample-time")
                    Spacer()
                    if player != nil {
                        Button("Jump to frame", action: jumpToFrame).controlSize(.mini).accessibilityIdentifier("appearance-jump-to-frame")
                    }
                }
            }
            if let features = payload?.imageFeatures, features.hasColorSummary {
                ImageColorStrip(features: features)
                Text(features.leadingColors).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("appearance-leading-colors")
            } else {
                Text("Color summary unavailable.").font(.caption).foregroundStyle(.secondary)
                    .help(payload?.summary ?? "The stored payload is missing or uses an unsupported format.")
            }
            DisclosureGroup("Technical details", isExpanded: $technicalDetails) {
                VStack(alignment: .leading, spacing: 9) {
                    MetadataFields(fields: VisualMetadata.explainedFields(row, table: "ZFEATUREVECTORRESULT"), table: "ZFEATUREVECTORRESULT")
                    if let payload {
                        Text(payload.summary).font(.caption).foregroundStyle(.secondary)
                        MetadataFields(fields: payload.fields)
                        if let features = payload.imageFeatures {
                            DisclosureGroup("Texture responses · 32 components") {
                                Chart(Array(features.textureResponses.enumerated()), id: \.offset) { item in
                                    BarMark(x: .value("Filter index", item.offset), y: .value("Quantized response", Double(item.element) / 65_535))
                                        .foregroundStyle(.teal)
                                }.frame(height: 135).chartXAxisLabel("Scale-major filter index")
                                    .chartYAxisLabel("Quantized response")
                                Text("Four scales × eight orientations. Values are stored UInt16 / 65535.").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    AnalysisRawFields(row: row)
                }.padding(.top, 5)
            }.font(.caption).accessibilityIdentifier("appearance-technical-details")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ImageColorStrip: View {
    let features: ImageFeatureDescriptor
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(features.colorGroups) { group in
                    Rectangle().fill(swatch(group.category))
                        .frame(width: geometry.size.width * Double(group.mass) / Double(features.colorMass))
                        .help(group.category.title + " · about " + group.percentage + " of the central crop")
                }
            }
        }.frame(height: 12).clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Approximate central color mix")
            .accessibilityValue(features.colorGroups.map { $0.category.title + " " + $0.percentage }.joined(separator: ", "))
            .accessibilityIdentifier("appearance-color-strip")
    }
    /// Representative colors for recovered categories, not sampled RGB colors.
    private func swatch(_ category: ImageColorCategory) -> Color {
        switch category {
        case .dark: Color(white: 0.16)
        case .gray: Color(white: 0.50)
        case .light: Color(white: 0.90)
        case .red: Color(hue: 0, saturation: 0.75, brightness: 0.85)
        case .orange: Color(hue: 34 / 360, saturation: 0.75, brightness: 0.90)
        case .yellow: Color(hue: 58 / 360, saturation: 0.70, brightness: 0.90)
        case .green: Color(hue: 112 / 360, saturation: 0.65, brightness: 0.70)
        case .cyan: Color(hue: 170 / 360, saturation: 0.65, brightness: 0.80)
        case .blue: Color(hue: 232 / 360, saturation: 0.65, brightness: 0.80)
        case .purple: Color(hue: 304 / 360, saturation: 0.60, brightness: 0.75)
        }
    }
}
