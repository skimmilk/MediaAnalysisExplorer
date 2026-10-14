import Foundation

/// Normalizes observed native spellings into the existing display vocabulary.
/// This constructs in-memory presentation records, never Photos/database rows.
/// The original value and every adapted field's source path remain available.
public enum LocalAnalysisDisplay {
    private static let tables: [String: String] = [
        "MiCaImageCaptionResults": "ZIMAGECAPTIONRESULT", "ImageCaptionResults": "ZIMAGECAPTIONRESULT",
        "MiCaVideoCaptionResults": "ZVIDEOCAPTIONRESULT", "ImageprintResults": "ZFEATUREVECTORRESULT",
        "FeatureVectorResults": "ZFEATUREVECTORRESULT", "ImageFeatureResults": "ZFEATUREVECTORRESULT",
        "MovingObjectsResults": "ZMOVINGOBJECTRESULT", "FacePrintResults": "ZFACEPRINTRESULT"
    ]
    private static let fields: [String: [String: String]] = [
        "ExposureResults": ["quality": "ZEXPOSURE", "attributes.underExpose": "ZUNDEREXPOSE"],
        "BlurResults": ["attributes.sharpness": "ZSHARPNESS", "attributes.faceSharpness": "ZFACESHARPNESS", "attributes.sharpnessFaces": "ZFACESHARPNESS"],
        "HumanPoseResults": ["attributes.humanConfidence": "ZCONFIDENCE"],
        "FaceResults": ["attributes.facePoseYaw": "ZYAW", "attributes.facePosition": "ZPOSITION"],
        "SaliencyResults": ["attributes.saliencyConfidence": "ZCONFIDENCE"],
        "ActivityLevelResults": ["quality": "ZACTIVITYSCORE"], "InterestingnessResults": ["quality": "ZINTERESTINGNESSSCORE"],
        "QualityResults": ["quality": "ZQUALITYSCORE"], "FineSubjectMotionResults": ["quality": "ZACTIONSCORE"],
        "SubtleMotionResults": ["quality": "ZSCORE"], "MovieHighlightScoreResults": ["quality": "ZSCORE"],
        "HumanActionResults": ["attributes.humanScore": "ZHUMANPOSESCORE", "attributes.absoluteScore": "ZMAXABSOLUTEACTIONSCORE", "attributes.relativeScore": "ZMAXRELATIVEACTIONSCORE"],
        "VoiceResults": ["quality": "ZCONFIDENCE"], "ApplauseResults": ["quality": "ZCONFIDENCE"],
        "BabbleResults": ["quality": "ZCONFIDENCE"], "CheeringResults": ["quality": "ZCONFIDENCE"], "MusicResults": ["quality": "ZCONFIDENCE"],
        "HumanActionClassificationResults": ["attributes.humanActions": "ZACTIONSCONFIDENCE"],
        "SafetyResults": ["attributes.SensitivitySceneResults": "ZSENSITIVITYSCENERESULTS"],
        "VideoEmbeddingResults": ["attributes.embeddings": "ZEMBEDDINGDATA"],
        "AudioFusedVideoEmbeddingResults": ["attributes.embeddings": "ZEMBEDDINGDATA"],
        "TorsoResults": ["attributes.faceId": "ZHUMANID"],
        "SummarizedEmbeddingResults": ["attributes.embeddingIds": "ZEMBEDDINGIDS", "attributes.representativeMapping": "ZREPRESENTATIVEMAPPING"]
    ]
    private static func scalar(_ value: AnalysisValue) -> String? {
        switch value {
        case .string(let v): v
        case .integer(let v): String(v)
        case .number(let v): String(v)
        case .bool(let v): v ? "1" : "0"
        default: nil
        }
    }
    /// One browser family per analysis type. Exact repeated observations share
    /// a row and retain all their sources; differing observations remain visible.
    public static func families(_ reports: [LocalAnalysisReport]) -> [ResultFamily] {
        var groups: [String: [AnalysisRecord]] = [:], columns: [String: [String: String]] = [:]
        var indices: [String: [Data: [Int]]] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for report in reports {
            for family in families(report) {
                if groups[family.id] == nil { groups[family.id] = [] }
                columns[family.id, default: [:]].merge(family.table.columns) { existing, _ in existing }
                for row in family.rows {
                    let key = (try? encoder.encode(row.fields)) ?? Data()
                    let candidates = indices[family.id]?[key] ?? []
                    if let index = candidates.first(where: { groups[family.id]![$0].fields == row.fields && groups[family.id]![$0].nativeEvidence == row.nativeEvidence }) {
                        let existing = groups[family.id]![index]
                        let sources = existing.analysisSources.contains(report.pass.title) ? existing.analysisSources : existing.analysisSources + [report.pass.title]
                        groups[family.id]![index] = AnalysisRecord(id: existing.id, fields: existing.fields, decoded: existing.decoded,
                            nativeEvidence: existing.nativeEvidence, fieldOrigins: existing.fieldOrigins, analysisSources: sources)
                    } else {
                        let index = groups[family.id]!.count
                        groups[family.id]!.append(AnalysisRecord(id: index + 1, fields: row.fields, decoded: row.decoded,
                            nativeEvidence: row.nativeEvidence, fieldOrigins: row.fieldOrigins, analysisSources: [report.pass.title]))
                        indices[family.id, default: [:]][key, default: []].append(index)
                    }
                }
            }
        }
        return groups.keys.sorted().map { table in
            ResultFamily(table: TableSchema(name: table, columns: columns[table] ?? [:]), count: groups[table]!.count, rows: groups[table]!)
        }
    }
    public static func families(_ report: LocalAnalysisReport) -> [ResultFamily] {
        report.families.flatMap { family in
            let table = tables[family.name] ?? "Z" + family.name.replacingOccurrences(of: "Results", with: "Result").uppercased()
            var rows: [AnalysisRecord] = [], aesthetics: [AnalysisRecord] = []
            for native in family.rows {
                if family.name == "ClassificationResults", !native["attributes"]["sceneClassification"].object.isEmpty {
                    for scene in native["attributes"]["sceneClassification"].object.keys.sorted() {
                        guard Int(scene) != nil else { continue }
                        let scores = native["attributes"]["sceneClassification"][scene]
                        var normalized = row(native, name: family.name, table: table, id: rows.count + 1)
                        var f = normalized.fields, origins = normalized.fieldOrigins
                        f["ZSCENEID"] = scene; origins["ZSCENEID"] = "attributes.sceneClassification." + scene
                        if let confidence = scalar(scores["Confidence"]) { f["ZCONFIDENCE"] = confidence; origins["ZCONFIDENCE"] = "attributes.sceneClassification.\(scene).Confidence" }
                        if let rect = scores["BoundingBox"].normalizedRectangle {
                            for (key, value) in zip(["ZX", "ZY", "ZWIDTH", "ZHEIGHT"], [rect.minX, rect.minY, rect.width, rect.height]) {
                                f[key] = String(Double(value)); origins[key] = "attributes.sceneClassification.\(scene).BoundingBox"
                            }
                        }
                        normalized = AnalysisRecord(id: normalized.id, fields: f, decoded: normalized.decoded, nativeEvidence: native, fieldOrigins: origins)
                        rows.append(normalized)
                    }
                    let aesthetic = native["attributes"]["aesthetic"]
                    if !aesthetic.object.isEmpty {
                        aesthetics.append(AnalysisRecord(id: aesthetics.count + 1, fields: aesthetic.object.compactMapValues(scalar), nativeEvidence: aesthetic,
                                                        fieldOrigins: Dictionary(uniqueKeysWithValues: aesthetic.object.keys.map { ($0, "attributes.aesthetic." + $0) })))
                    }
                } else { rows.append(row(native, name: family.name, table: table, id: rows.count + 1)) }
            }
            if rows.isEmpty, !family.evidence.isNull, family.evidence["count"].integer == nil {
                rows = [AnalysisRecord(id: 1, fields: ["Native result": family.evidence.summary], nativeEvidence: family.evidence)]
            }
            let main = ResultFamily(table: TableSchema(name: table, columns: Dictionary(uniqueKeysWithValues: Set(rows.flatMap { $0.fields.keys }).map { ($0, "display") })), count: rows.count, rows: rows)
            if aesthetics.isEmpty { return [main] }
            return [main, ResultFamily(table: TableSchema(name: "ZAESTHETICSRESULT", columns: [:]), count: aesthetics.count, rows: aesthetics)]
        }
    }
    private static func row(_ native: AnalysisValue, name: String, table: String, id: Int) -> AnalysisRecord {
        var result: [String: String] = [:], origins: [String: String] = [:], decoded: [String: DecodedPayload] = [:]
        var aliases = fields[name] ?? [:]
        if name.contains("Caption") {
            let image = name.contains("Image")
            aliases["attributes." + (image ? "imageCaptionText" : "videoCaptionText")] = "ZCAPTION"
            aliases["attributes." + (image ? "imageCaptionConfidence" : "videoCaptionConfidence")] = "ZCONFIDENCE"
            if image { aliases["attributes.imageCaptionUnsafeContent"] = "ZISUNSAFE" }
        }
        func add(_ key: String, _ value: AnalysisValue, path: String) {
            if let text = scalar(value) { result[key] = text; origins[key] = path }
            else if ["ZSENSITIVITYSCENERESULTS", "ZACTIONSCONFIDENCE"].contains(key), !value.object.isEmpty {
                let scores = value.object.filter { !$0.key.hasPrefix("__") && !$0.key.hasPrefix("$") }.compactMapValues(\.double)
                if let payload = AnalysisPayload.decodeScores(scores, column: key) {
                    result[key] = "\(scores.count) scores"; origins[key] = path; decoded[key] = payload
                }
            }
            else if value["class"].text == "NSData", let bytes = value["bytes"].integer, bytes <= 65536,
                    let base64 = value["base64"].text, base64.count <= 90_000, let data = Data(base64Encoded: base64), data.count == bytes {
                result[key] = "\(bytes) bytes"; origins[key] = path
                decoded[key] = AnalysisPayload.decode(data, column: key, table: table)
            }
            else if !value.isNull {
                // Keep opaque/large payloads and native collections visible,
                // without treating a count or byte size as decoded semantics.
                result[key] = value.summary; origins[key] = path
            }
        }
        for (prefix, object) in [("", native.object), ("attributes.", native["attributes"].object)] {
            for (key, value) in object {
                if prefix.isEmpty, ["attributes", "start", "duration", "timestamp", "keyFrameTime"].contains(key) { continue }
                let path = prefix + key
                let column = aliases[path] ?? "Z" + key.uppercased()
                add(column, value, path: path)
            }
        }
        // Explicit geometry keys have been compared with the persisted layout.
        for key in ["bounds", "faceBounds", "humanBounds", "petsBounds", "saliencyBounds", "bestPlaybackCrop"] {
            guard let rect = native["attributes"][key].normalizedRectangle ?? native[key].normalizedRectangle else { continue }
            let columns: [String]
            if name == "FaceResults" && key == "humanBounds" { columns = ["ZTORSOX", "ZTORSOY", "ZTORSOWIDTH", "ZTORSOHEIGHT"] }
            else if key == "petsBounds" { columns = ["ZPETSBOUNDX", "ZPETSBOUNDY", "ZPETSBOUNDWIDTH", "ZPETSBOUNDHEIGHT"] }
            else if key == "bestPlaybackCrop" { columns = ["ZBESTPLAYBACKCROPX", "ZBESTPLAYBACKCROPY", "ZBESTPLAYBACKCROPWIDTH", "ZBESTPLAYBACKCROPHEIGHT"] }
            else { columns = ["ZX", "ZY", "ZWIDTH", "ZHEIGHT"] }
            for (column, value) in zip(columns, [rect.minX, rect.minY, rect.width, rect.height]) {
                result[column] = String(Double(value)); origins[column] = "attributes." + key
            }
        }
        for (key, prefix) in [("start", "ZSTARTTIME"), ("duration", "ZDURATIONTIME"), ("timestamp", "ZTIMESTAMP"), ("keyFrameTime", "ZKEYFRAMETIME")] {
            let time = native[key]
            guard time.seconds != nil else { continue }
            result[prefix + "VALUE"] = scalar(time["value"]); origins[prefix + "VALUE"] = key + ".value"
            result[prefix + "SCALE"] = scalar(time["timescale"]); origins[prefix + "SCALE"] = key + ".timescale"
        }
        return AnalysisRecord(id: id, fields: result, decoded: decoded, nativeEvidence: native, fieldOrigins: origins)
    }
}
