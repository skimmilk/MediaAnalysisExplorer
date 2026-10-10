/// Explicit MediaAnalysis special-label IDs, verified on macOS build 26A434.
/// See research-notes/sensitivity for static constants and native round trips.
/// These IDs are separate from scene taxonomy IDs and SafetyNet channel offsets.
public enum SensitivityLabels {
    public static func name(for id: Int) -> String? { names[id] }

    private static let names: [Int: String] = [
        2147481342: "SafetyNet Lite gore",
        2147481343: "SafetyNet Lite violence",
        2147481844: "NSFW racy",
        2147481845: "NSFW racy explicit",
        2147481846: "NSFW female breast",
        2147481847: "NSFW male breast",
        2147481848: "NSFW buttocks",
        2147481849: "NSFW female genitals",
        2147481850: "NSFW male genitals",
        2147481851: "NSFW none",
        2147481852: "NSFW underwear",
        2147481853: "NSFW any",
        2147481854: "NSFW explicit",
        2147481855: "NSFW genitals",
    ]

    public static let evidence = "14 explicit MediaAnalysis label IDs verified on macOS build 26A434; historical/future revision compatibility unverified. Unknown IDs remain unresolved."
    public static let scoreInterpretation = "Percentages are stored classification scores multiplied by 100; probability calibration unverified. Raw scores remain in the archived sensitivity scores section. The verified video pipeline retains per-label maxima over sampled analysis results. NSFW any belongs to the nudity/NSFW family. The sensitivity decision mask is stored separately."
}
