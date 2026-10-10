import Foundation

/// Build-scoped explanations. Unknown masks retain their raw values; observed
/// correlations are deliberately not promoted to enum definitions.
public enum AnalysisFieldInterpretation {
    /// Categorical values from MediaAnalysisShotType on build 26A434.
    /// This reads the result's ZSHOTTYPE, never the parent's row reference.
    public static func shotTypeLabel(_ value: Int) -> String {
        switch value {
        case 0: "Unknown / unspecified"
        case 1: "Close-up"
        case 2: "Mid shot"
        case 3: "Wide shot"
        case 4: "Very wide shot"
        default: "Unknown (\(value))"
        }
    }
    public static func faceAttributes(_ flags: UInt64) -> [String] {
        let names: [(UInt64, String)] = [(2, "smile"), (4, "both eyes closed"), (8, "one/either eye closed"), (16, "close-up")]
        return names.filter { flags & $0.0 != 0 }.map(\.1)
    }
    public static func faceFlagLabels(_ flags: UInt64) -> [String] {
        let unknown = flags & ~UInt64(30)
        return faceAttributes(flags) + (unknown == 0 ? [] : [String(format: "unknown flags 0x%llX", unknown)])
    }
    public static func fields(_ row: DBRow, table: String) -> [String: String] {
        var notes: [String: String] = [:]
        if table == "ZSHOTTYPERESULT", let value = Int(row["ZSHOTTYPE"]) {
            notes["Shot type"] = shotTypeLabel(value)
            notes["Shot type evidence"] = "Recovered from Apple's MediaAnalysisShotType and named threshold exports on build 26A434. Categories describe framing from the largest accepted face: close-up approximately ≥45%, mid shot 25–45%, wide shot 10–25%, and very wide shot >0–10% of a linear image dimension. Scalar preparation varies by face source. Value 0 is a zero/invalid-size fallback; its label is inferred. Missing results and unknown integer values are distinct."
        }
        if table == "ZFACERESULT" {
            if let flags = UInt64(row["ZFLAGS"]) {
                let named = faceAttributes(flags)
                notes["Face flags"] = named.isEmpty ? "No named attribute bits set" : named.joined(separator: ", ")
                if flags & ~UInt64(30) != 0 { notes["Unknown face flag bits"] = String(format: "0x%llX", flags & ~UInt64(30)) }
                notes["Face flag evidence"] = "Installed PHAsset face converter maps smile/eye-state selectors and max(normalized width,height) ≥ 0.45 to these bits. Close-up condition matches all 135 captured rows. These are stored detector attributes; absent bits do not prove a negative observation."
            }
            if let mask = UInt64(row["ZPOSITION"]) {
                let names: [(UInt64, String)] = [(1, "top"), (2, "right"), (4, "bottom"), (8, "left"), (16, "center")]
                let named = names.filter { mask & $0.0 != 0 }.map(\.1)
                notes["Position regions"] = named.isEmpty ? "No named region bits set" : named.joined(separator: ", ")
                if mask & ~UInt64(31) != 0 { notes["Unknown position bits"] = String(format: "0x%llX", mask & ~UInt64(31)) }
                notes["Position evidence"] = "Installed helper classifies box centers at 0.25/0.75 boundaries. It reproduces 102/135 captured rows; stored masks can combine observations. This is position in the image, not a body pose or exact current-frame location."
            }
            if let yaw = Int(row["ZYAW"]), (0...4).contains(yaw) {
                notes["Yaw interpretation"] = "Coarse bin \(yaw) of 0…4. Installed helper truncates radians / (π/6), clamps to −2…2 and adds 2. Handedness and per-result compatibility remain unverified; this is not degrees."
            }
            if row["ZFACEID"] != "NULL" { notes["Face reference scope"] = "Join face descriptors using this asset AND face ID; IDs repeat across assets."
            }
        }
        if table == "ZHUMANPOSERESULT" {
            if let flags = UInt64(row["ZFLAGS"]) {
                notes["Pose flag structure"] = "Bits 20–23 give nibble \((flags >> 20) & 15). Installed flagsFromKeypoints helper tests confidence-supported joint groups. These flags do not encode coordinates; exact joint-name mapping remains build-scoped."
                let predicates: [(Int, String)] = [(20, "≥3 of indices 0–4 and one of 0–2"), (21, "one of 5/6 and one of 11/12"), (22, "one of 7/8"), (23, "one of 13/14")]
                let supported = predicates.filter { flags & (UInt64(1) << $0.0) != 0 }.map { "bit \($0.0): \($0.1)" }
                notes["Supported pose groups"] = supported.isEmpty ? "No supported group bits set" : supported.joined(separator: "; ")
                notes["Pose group evidence"] = "Each predicate tests keypoint confidence above a supplied threshold. Threshold and coordinates are not stored here; anatomical joint names from apparent ordering remain inferred."
            }
            if row["ZKEYPOINTS"] == "NULL" { notes["Pose geometry"] = "No joint/keypoint data stored in this row. The bounding box is available; flags and descriptors cannot supply a skeleton." }
        }
        if table.contains("MOTION"), let flags = UInt64(row["ZFLAGS"]) {
            notes["Motion flag interpretation"] = "Installed export/converter reference on 26A434; semantic motion category names remain unresolved. Flags are not probabilities."
            if table == "ZCAMERAMOTIONRESULT" {
                notes["Fast camera motion flag"] = flags & 0x10000 != 0 ? "isFast bit 16 is set" : "isFast bit 16 is not set"
                let types = (1...9).filter { flags & (UInt64(1) << ($0 + 5)) != 0 }
                notes["Camera motion type IDs"] = types.isEmpty ? "No recognized category bits set" : types.map(String.init).joined(separator: ", ")
                if flags & 0x8000 != 0 { notes["Camera motion fallback"] = "Unrecognized motionType branch · bit 15" }
            }
            if table == "ZSUBJECTMOTIONRESULT" { notes["Subject action flag"] = flags & 0x20000 != 0 ? "hasAction bit 17 is set" : "hasAction bit 17 is not set" }
        }
        if table == "ZASSET" {
            if row["ZSTATSFLAGS"] != "NULL" { notes["Statistics flag evidence"] = "Captured stills had 1 and videos 5; bit 2 correlated with video in this small cohort. Its definition is unverified." }
            notes["Version interpretation"] = "Asset, family, descriptor and graph versions are separate namespaces. A nonzero family version does not guarantee result rows: captured transcription versions were populated but transcription tables empty."
            for key in ["ZDATEANALYZED", "ZDATEMODIFIED"] {
                if let seconds = Double(row[key]), seconds.isFinite, seconds > 0, seconds < 100_000_000_000 {
                    notes[key + " · reference-date interpretation"] = Date(timeIntervalSinceReferenceDate: seconds).formatted(.iso8601) + " · seconds since 2001-01-01; corroborated against captured transaction times."
                }
            }
        }
        if table == "ZLOUDNESSRESULT" { notes["Audio-level evidence"] = "Installed LkFsMeasure calls support LKFS-style loudness; peak path uses maximum magnitude. Persisted calibration/gating/window remain unverified. Values are plotted in stored units, not acoustic sound-pressure dB." }
        if table == "ZSAFETYRESULT" {
            notes["Sensitivity label evidence"] = SensitivityLabels.evidence
            notes["Sensitivity score interpretation"] = SensitivityLabels.scoreInterpretation
        }
        if table == "ZORIENTATIONRESULT" { notes["Orientation limitation"] = "Captured videos all stored 3. Private enum compatibility is unverified; do not substitute EXIF orientation names." }
        if table == "ZSUMMARIZEDEMBEDDINGRESULT" { notes["Summary reference interpretation"] = "Embedding/thumbnail IDs resolve within their own asset. Representative arrays differ in length and can repeat; they are not a validated one-to-one zip or filesystem paths." }
        return notes
    }
}
