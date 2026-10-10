import Foundation

/// Recovered ColorGabor layout on 26A434. Image features stay separate from
/// learned vectors so generic cosine comparison cannot be applied to them.
public struct ImageFeatureDescriptor: Sendable, Equatable {
    public let textureResponses: [UInt16]
    public let colorBins: [UInt16]
    public static let explanation = "Colors near the image’s center and texture patterns help compare its appearance with other images."

    init?(textureResponses: [UInt16], colorBins: [UInt16]) {
        guard textureResponses.count == 32, colorBins.count == 36 else { return nil }
        self.textureResponses = textureResponses; self.colorBins = colorBins
    }

    public var colorMass: Int { colorBins.reduce(0) { $0 + Int($1) } }
    /// A normalized 36-bin histogram loses fewer than 36 integer units when
    /// independently truncated. Do not manufacture colors from invalid mass.
    public var hasColorSummary: Bool { (65_500...65_535).contains(colorMass) }
    public var colorGroups: [ImageColorGroup] {
        guard hasColorSummary else { return [] }
        return ImageColorCategory.allCases.compactMap { category in
            let mass = category.binIndices.reduce(0) { $0 + Int(colorBins[$1]) }
            return mass > 0 ? ImageColorGroup(category: category, mass: mass) : nil
        }.sorted {
            $0.mass == $1.mass ? $0.category.rawValue < $1.category.rawValue : $0.mass > $1.mass
        }
    }
    public var leadingColors: String { colorGroups.prefix(3).map { $0.category.title }.joined(separator: " · ") }
}

public enum ImageColorCategory: Int, CaseIterable, Sendable {
    case dark, gray, light, red, orange, yellow, green, cyan, blue, purple
    public var title: String {
        switch self {
        case .dark: "Dark tones"
        case .gray: "Gray"
        case .light: "Light gray / white"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .cyan: "Cyan"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }
    var binIndices: Range<Int> {
        switch self {
        case .dark: 0..<1
        case .gray: 1..<7
        case .light: 7..<8
        default: (8 + (rawValue - 3) * 4)..<(12 + (rawValue - 3) * 4)
        }
    }
}

public struct ImageColorGroup: Identifiable, Sendable, Equatable {
    public let category: ImageColorCategory
    public let mass: Int
    public var id: ImageColorCategory { category }
    public var fraction: Double { Double(mass) / 65_535 }
    public var percentage: String { fraction < 0.01 ? "<1%" : String(format: "%.0f%%", fraction * 100) }
}

/// Keep stored sample time distinct from an interval or current player frame.
public enum ImageFeatureSamples {
    public static func ordered(_ rows: [DBRow]) -> [DBRow] {
        rows.sorted {
            let a = time($0) ?? .infinity, b = time($1) ?? .infinity
            if a != b { return a < b }
            let ka = Int64($0["Z_PK"]) ?? Int64($0.id), kb = Int64($1["Z_PK"]) ?? Int64($1.id)
            return ka == kb ? $0.id < $1.id : ka < kb
        }
    }
    public static func time(_ row: DBRow) -> Double? {
        guard let time = VisualMetadata.seconds(row, value: "ZSTARTTIMEVALUE", scale: "ZSTARTTIMESCALE"), time >= 0 else { return nil }
        return time
    }
    public static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1_000) else { return "Time unavailable" }
        let milliseconds = Int((seconds * 1_000).rounded()), totalSeconds = milliseconds / 1_000
        let base = totalSeconds >= 3_600 ? "\(totalSeconds / 3_600):" + String(format: "%02d:%02d", totalSeconds / 60 % 60, totalSeconds % 60)
            : String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
        return milliseconds % 1_000 == 0 ? base : base + String(format: ".%03d", milliseconds % 1_000)
    }
}
