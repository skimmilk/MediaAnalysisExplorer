import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

public struct StoredRegion: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let table: String
    public let record: String
    public let rectangle: CGRect
    public let fields: [String: String]
    public let start: Double?
    public let duration: Double?
    public let actionProbabilities: [ActionProbability]

    public init(id: String, title: String, table: String, record: String, rectangle: CGRect, fields: [String: String], start: Double?, duration: Double?, actionProbabilities: [ActionProbability] = []) {
        self.id = id; self.title = title; self.table = table; self.record = record; self.rectangle = rectangle
        self.fields = fields; self.start = start; self.duration = duration; self.actionProbabilities = actionProbabilities
    }

    public var overlayDetails: [String] {
        if !actionProbabilities.isEmpty { return actionProbabilities.map(\.displayText) }
        if table == "ZFACERESULT", let value = fields["ZFLAGS"],
           let flags = UInt64(value) ?? Int64(value).map({ UInt64(bitPattern: $0) }) {
            let labels = AnalysisFieldInterpretation.faceFlagLabels(flags)
            if !labels.isEmpty { return [labels.joined(separator: ", ")] }
        }
        return []
    }

    public func overlayLabel(focused: Bool) -> String {
        let heading = "\(title) #\(record)"
        if focused, !overlayDetails.isEmpty {
            return ([heading] + overlayDetails).joined(separator: "\n")
        }
        return heading
    }

    public func visible(at seconds: Double?) -> Bool {
        guard let seconds, let start else { return true }
        guard let duration, duration > 0 else { return abs(seconds - start) < 0.15 }
        return seconds >= start && seconds < start + duration
    }
}

public enum VisualMetadata {
    public static func title(_ table: String) -> String {
        let names = ["ZHUMANPOSERESULT": "Human pose", "ZFACERESULT": "Face", "ZFACEPRINTRESULT": "Face/torso descriptors",
                     "ZTORSORESULT": "Torso", "ZSALIENCYRESULT": "Salient region", "ZPETSRESULT": "Pet", "ZPETSFACERESULT": "Pet face",
                     "ZHUMANACTIONRESULT": "Human action", "ZHUMANACTIONCLASSIFICATIONRESULT": "Action classification",
                     "ZIMAGECAPTIONRESULT": "Image caption", "ZVIDEOCAPTIONRESULT": "Video caption", "ZVIDEOSEGMENTCAPTIONRESULT": "Segment caption",
                     "ZBLURRESULT": "Sharpness", "ZEXPOSURERESULT": "Exposure", "ZCLASSIFICATIONRESULT": "Scene classification", "ZSHOTTYPERESULT": "Shot type",
                     "ZFEATUREVECTORRESULT": "Colors & texture", "ZWORDLEVELTRANSCRIPTIONRESULT": "Transcribed words",
                     "ZSENTENCELEVELTRANSCRIPTIONRESULT": "Transcribed sentences", "ZKEYFRAMERESULT": "Keyframes", "ZLOUDNESSRESULT": "Audio levels",
                     "ZMOVINGOBJECTRESULT": "Moving objects", "ZMOVIEHIGHLIGHTRESULT": "Playback highlights", "ZMOVIEHIGHLIGHTSCORERESULT": "Highlight scores",
                     "ZMOVIESUMMARYRESULT": "Playback summary", "ZVIDEOEMBEDDINGRESULT": "Video embeddings", "ZAUDIOFUSEDVIDEOEMBEDDINGRESULT": "Audio/video embeddings",
                     "ZSUMMARIZEDEMBEDDINGRESULT": "Embedding summary", "ZCHEERINGRESULT": "Cheering", "ZAPPLAUSERESULT": "Applause", "ZVOICERESULT": "Voice activity",
                     "ZBABBLERESULT": "Babble", "ZAUDIOQUALITYRESULT": "Audio quality", "ZACTIVITYLEVELRESULT": "Activity level", "ZINTERESTINGNESSRESULT": "Interestingness",
                     "ZCAMERAMOTIONRESULT": "Camera motion", "ZSUBJECTMOTIONRESULT": "Subject motion", "ZFINESUBJECTMOTIONRESULT": "Fine subject motion",
                     "ZSUBTLEMOTIONRESULT": "Subtle motion", "ZQUALITYRESULT": "Video quality", "ZSAFETYRESULT": "Sensitivity", "ZSCENERESULT": "Scene segments",
                     "ZVIDEOTHUMBNAILRESULT": "Video thumbnails", "ZVIDEOSCENETHUMBNAILRESULT": "Scene thumbnail references", "ZORIENTATIONRESULT": "Orientation"]
        return names[table] ?? table.dropFirst().replacingOccurrences(of: "RESULT", with: "").localizedCapitalized
    }
    public static func seconds(_ row: DBRow, value: String, scale: String) -> Double? {
        guard let v = Double(row[value]), let s = Double(row[scale]), v.isFinite, s.isFinite, s > 0 else { return nil }
        let result = v / s
        return result.isFinite ? result : nil
    }
    public static func eventTime(_ row: DBRow) -> Double? {
        seconds(row, value: "ZSTARTTIMEVALUE", scale: "ZSTARTTIMESCALE") ?? seconds(row, value: "ZTIMESTAMPVALUE", scale: "ZTIMESTAMPSCALE")
    }
    /// These column groups describe rectangles. Units/origin are private and remain an explicit viewing assumption.
    public static func regions(_ family: ResultFamily) -> [StoredRegion] {
        let groups = [("", ["ZX", "ZY", "ZWIDTH", "ZHEIGHT"]),
                      (" torso", ["ZTORSOX", "ZTORSOY", "ZTORSOWIDTH", "ZTORSOHEIGHT"]),
                      ("", ["ZPETSBOUNDX", "ZPETSBOUNDY", "ZPETSBOUNDWIDTH", "ZPETSBOUNDHEIGHT"]),
                      (" playback crop", ["ZBESTPLAYBACKCROPX", "ZBESTPLAYBACKCROPY", "ZBESTPLAYBACKCROPWIDTH", "ZBESTPLAYBACKCROPHEIGHT"])]
        return family.rows.flatMap { row -> [StoredRegion] in
            let direct = groups.compactMap { suffix, keys -> StoredRegion? in
                let values = keys.compactMap { Double(row[$0]) }
                guard values.count == 4, values.allSatisfy({ $0.isFinite }), values[0] >= 0, values[1] >= 0,
                      values[2] > 0, values[3] > 0, values[0] + values[2] <= 1.00001, values[1] + values[3] <= 1.00001 else { return nil }
                let record = row.fields["Z_PK"] ?? String(row.id)
                return StoredRegion(id: "\(family.id):\(record):\(keys[0])", title: title(family.id) + suffix,
                                    table: family.id, record: record,
                                    rectangle: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]), fields: row.fields,
                                    start: eventTime(row),
                                    duration: seconds(row, value: "ZDURATIONTIMEVALUE", scale: "ZDURATIONTIMESCALE"),
                                    actionProbabilities: row.decoded["ZACTIONSCONFIDENCE"]?.actionProbabilities ?? [])
            }
            let archived = row.decoded.keys.sorted().flatMap { column in
                (row.decoded[column]?.rectangles ?? []).enumerated().map { index, value in
                    StoredRegion(id: "\(family.id):\(row["Z_PK"]):\(column):\(index)", title: value.title, table: family.id,
                                 record: row.fields["Z_PK"] ?? String(row.id), rectangle: value.rectangle,
                                 fields: row.fields.merging(value.fields, uniquingKeysWith: { _, decoded in decoded }),
                                 start: eventTime(row), duration: seconds(row, value: "ZDURATIONTIMEVALUE", scale: "ZDURATIONTIMESCALE"))
                }
            }
            return direct + archived
        }
    }
    public static func explainedFields(_ row: DBRow, table: String, taxonomy: AnalysisTaxonomy = .installed) -> [String: String] {
        var fields = meaningfulFields(row)
        fields.merge(AnalysisFieldInterpretation.fields(row, table: table)) { _, note in note }
        if let id = Int(row["ZSCENEID"]), let label = taxonomy.scenes[id] { fields["Scene label · installed taxonomy"] = label }
        if let flags = UInt64(row["ZFLAGS"]) {
            fields["Flag structure · meanings unresolved"] = String(format: "0x%llX", flags) + " · set bits " + (0..<64).filter { flags & (UInt64(1) << $0) != 0 }.map(String.init).joined(separator: ", ")
        }
        if let mask = UInt64(row["ZANALYSISTYPES"]) ?? Int64(row["ZANALYSISTYPES"]).map({ UInt64(bitPattern: $0) }) {
            fields.merge(AnalysisTypeReference.describe(mask)) { _, interpretation in interpretation }
        }
        if let time = eventTime(row) { fields["Time · seconds"] = String(format: "%.6f", time) }
        if let duration = seconds(row, value: "ZDURATIONTIMEVALUE", scale: "ZDURATIONTIMESCALE") { fields["Duration · seconds"] = String(format: "%.6f", duration) }
        if let keyframe = seconds(row, value: "ZKEYFRAMETIMEVALUE", scale: "ZKEYFRAMETIMESCALE") { fields["Representative frame · seconds"] = String(format: "%.6f", keyframe) }
        if let actions = row.decoded["ZACTIONSCONFIDENCE"] {
            fields["Top stored action scores"] = actions.actionProbabilities.prefix(3).map(\.displayText).joined(separator: "; ")
            fields["Action label evidence"] = actions.fields["Label evidence"]
        }
        return fields
    }
    public static func explanation(_ table: String) -> String? {
        switch table {
        case "ZSHOTTYPERESULT": "Framing based on face size: close-up, mid shot, wide shot, or very wide shot."
        case "ZFACEPRINTRESULT": "Numeric face and torso features used to compare detections."
        case "ZKEYFRAMERESULT": "Frames selected to represent the video, with scores and face regions."
        case "ZVIDEOEMBEDDINGRESULT", "ZAUDIOFUSEDVIDEOEMBEDDINGRESULT", "ZSUMMARIZEDEMBEDDINGRESULT": "Numeric features representing video or combined audio and video content."
        case "ZFEATUREVECTORRESULT": ImageFeatureDescriptor.explanation
        case "ZMOVIEHIGHLIGHTRESULT", "ZMOVIESUMMARYRESULT": "Selected playback intervals, representative frames, and crop regions."
        default: nil
        }
    }
    public static func imageFrame(image: CGSize, container: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
    public static func project(_ rectangle: CGRect, into frame: CGRect, bottomOrigin: Bool) -> CGRect {
        CGRect(x: frame.minX + rectangle.minX * frame.width,
               y: frame.minY + (bottomOrigin ? 1 - rectangle.maxY : rectangle.minY) * frame.height,
               width: rectangle.width * frame.width, height: rectangle.height * frame.height)
    }
    public static func hit(_ point: CGPoint, regions: [StoredRegion], frame: CGRect, bottomOrigin: Bool) -> StoredRegion? {
        regions.filter { project($0.rectangle, into: frame, bottomOrigin: bottomOrigin).contains(point) }
            .min { $0.rectangle.width * $0.rectangle.height < $1.rectangle.width * $1.rectangle.height }
    }
    /// Canvas paints back to front. Keep normal ordering stable, then bring
    /// the pin and the current hover forward, with the hover last.
    public static func overlayOrder(_ regions: [StoredRegion], hovered: String?, pinned: String?) -> [StoredRegion] {
        regions.filter { $0.id != hovered && $0.id != pinned }
            + regions.filter { $0.id == pinned && $0.id != hovered }
            + regions.filter { $0.id == hovered }
    }
    public static func meaningfulFields(_ row: DBRow) -> [String: String] {
        row.fields.filter { key, value in
            !["Z_PK", "Z_ENT", "Z_OPT", "ZASSET"].contains(key) && value != "NULL"
        }
    }
    private static let fieldLabels: [String: String] = [
        "ZCAPTION": "Generated caption",
        "ZTEXT": "Text",
        "ZCONFIDENCE": "Confidence",
        "ZISUNSAFE": "Unsafe flag",
        "ZSHARPNESS": "Sharpness score",
        "ZFACESHARPNESS": "Face sharpness score",
        "ZEXPOSURE": "Exposure score",
        "ZUNDEREXPOSE": "Underexposure score",
        "ZKEYPOINTS": "Pose keypoints",
        "ZSCENEID": "Scene ID (undecoded)",
        "ZFEATUREVECTOR": "Image feature record",
        "ZACTIONSCONFIDENCE": "Action score payload (raw)",
        "ZX": "X coordinate",
        "ZY": "Y coordinate",
        "ZWIDTH": "Region width",
        "ZHEIGHT": "Region height",
        "ZFACEID": "Face identifier",
        "ZHUMANID": "Human identifier",
        "ZQUALITY": "Quality score",
        "ZPETSCONFIDENCE": "Pet confidence",
        "ZTORSOX": "Torso X",
        "ZTORSOY": "Torso Y",
        "ZTORSOWIDTH": "Torso width",
        "ZTORSOHEIGHT": "Torso height",
        "ZFLAGS": "Flags (raw)",
        "ZPOSITION": "Position mask (raw)",
        "ZYAW": "Yaw bin (raw)",
        "ZORIENTATION": "Orientation ID (unresolved)",
        "ZSHOTTYPE": "Shot type ID (raw)",
        "ZSHOTTYPERESULT": "Shot-type result reference",
        "ZSHOTTYPEVERSION": "Shot-type analysis version",
        "ZEMBEDDINGID": "Embedding reference ID",
        "ZEMBEDDINGVERSION": "Embedding version",
        "ZEMBEDDINGDATA": "Embedding payload",
        "ZEMBEDDINGIDS": "Embedding reference list",
        "ZREPRESENTATIVEMAPPING": "Representative mapping",
        "ZTHUMBNAILIDS": "Thumbnail reference list",
        "ZTHUMBNAILID": "Thumbnail reference",
        "ZFACEPRINT": "Archived face descriptor",
        "ZFACERESULTS": "Archived keyframe faces",
        "ZOBJECTBOUNDS": "Archived object bounds",
        "ZTORSOPRINT": "Torso descriptor payload",
        "ZCOLORNORMALIZATIONDATA": "Stored color adjustments",
        "fp_conf": "Face descriptor confidence",
        "tp_conf": "Torso descriptor confidence",
        "descriptorData": "Raw descriptor data",
        "descriptorByteLength": "Declared descriptor bytes",
        "elementCount": "Declared components",
        "elementsType": "Declared element type",
        "ZSENSITIVITYSCENERESULTS": "Archived sensitivity scores",
        "ZSENSITIVITY": "Sensitivity ID (unresolved)",
        "ZSTARTTIMEVALUE": "Start time ticks",
        "ZSTARTTIMESCALE": "Start ticks/second",
        "ZDURATIONTIMEVALUE": "Duration ticks",
        "ZDURATIONTIMESCALE": "Duration ticks/second",
        "ZTIMESTAMPVALUE": "Frame timestamp ticks",
        "ZTIMESTAMPSCALE": "Frame ticks/second",
        "ZKEYFRAMETIMEVALUE": "Keyframe time ticks",
        "ZKEYFRAMETIMESCALE": "Keyframe ticks/second",
        "ZENERGYVALUES": "Energy (stored units)",
        "ZPEAKVALUES": "Peak (stored units)",
        "ZQUALITYSCORE": "Quality score",
        "ZACTIVITYSCORE": "Activity score",
        "ZINTERESTINGNESSSCORE": "Interestingness score",
        "ZACTIONSCORE": "Action score",
        "ZHUMANPOSESCORE": "Human pose score",
        "ZMAXABSOLUTEACTIONSCORE": "Maximum absolute action score",
        "ZMAXRELATIVEACTIONSCORE": "Maximum relative action score",
        "ZCONTENTSCORE": "Content score",
        "ZEXPOSURESCORE": "Exposure score",
        "ZFRAMEQUALITYSCORE": "Frame quality score",
        "ZFACEQUALITYSCORE": "Face quality score",
        "ZEXPRESSIONCHANGESCORE": "Expression change score",
        "ZGLOBALQUALITYSCORE": "Global quality score",
        "ZPENALTYSCORE": "Penalty score",
        "ZSHARPNESSSCORE": "Sharpness score",
        "ZTEXTURESCORE": "Texture score",
        "ZTHUMBNAILSCORE": "Thumbnail score",
        "ZVISUALPLEASINGSCORE": "Visual appeal score",
        "ZKEYFRAMESCORE": "Representative frame score",
        "ZBESTPLAYBACKCROPX": "Playback crop X",
        "ZBESTPLAYBACKCROPY": "Playback crop Y",
        "ZBESTPLAYBACKCROPWIDTH": "Playback crop width",
        "ZBESTPLAYBACKCROPHEIGHT": "Playback crop height",
        "ZAUDIOQUALITY": "Audio quality score",
        "ZSCENEPRINTDISTANCE": "Scene descriptor distance",
        "ZDISTANCE": "Distance (stored units)",
        "algorithmVersion": "Algorithm version",
        "$archiveClass": "Declared archive class",
        "faceQuality": "Face quality",
        "faceBounds": "Face bounds"
    ]
    public static func label(_ key: String) -> String { fieldLabels[key] ?? key }
}

public struct MediaPreview: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let video: Bool
}

public enum PreviewReader {
    public static func read(_ url: URL, budget: WorkBudget) throws -> MediaPreview {
        try budget.check()
        let image: CGImage
        let video: Bool
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2000] as CFDictionary) {
            image = thumbnail; video = false
        } else {
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true else { throw ExplorerError("No readable image preview for this original.") }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 2000, height: 2000)
            image = try generator.copyCGImage(at: .zero, actualTime: nil); video = true
        }
        try budget.check()
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw ExplorerError("Unable to encode preview.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExplorerError("Unable to finish preview.") }
        return MediaPreview(data: bytes as Data, width: image.width, height: image.height, video: video)
    }
}
