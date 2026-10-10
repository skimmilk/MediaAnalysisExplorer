import XCTest
import CryptoKit
@testable import ExplorerCore

final class SceneTaxonomyTests: XCTestCase {
    private struct Projection: Decodable {
        let declaredDigest: String
        let nodes: [String: Record]
        struct Record: Decodable {
            let sceneID: UInt64
            let networkID: UInt32
            let indexed: Bool
            let thresholds: [String: Double]
            let parents: [String]
            let children: [String]
            let detectors: [String]
        }
    }
    private let source = TaxonomySource(url: URL(fileURLWithPath: "/fixture/PFSceneTaxonomyData_99.bz2"), isCache: false)
    private var smallSource: String {
        "s:" + String(repeating: "a", count: 64) + "\nc:fixture\nn:493,1,1,0.2,0.03,0.07,0.01,0.15,0.02,dog\nn:111,1,1,0.3,0.04,0.08,0.02,0.16,0.03,canine\ne:canine,dog\nd:dog:canine\n"
    }
    func testSourceGrammarThresholdSemanticsAndSynonymSearch() throws {
        let value = try SceneTaxonomyReader.decodeArchive(Data(smallSource.utf8), source: source)
        let dog = try XCTUnwrap(value.nodes["dog"])
        XCTAssertEqual(dog.sceneID, 493); XCTAssertEqual(dog.parents, ["canine"]); XCTAssertEqual(dog.detectors, ["canine"])
        XCTAssertEqual(dog.thresholds["precision0Point6Threshold"], 0.03)
        XCTAssertEqual(dog.thresholds["highRecallThreshold"], 0.07)
        XCTAssertEqual(dog.thresholds["f2Threshold"], 0.01)
        XCTAssertEqual(dog.thresholds["graphHighPrecisionThreshold"], 0.01)
        XCTAssertEqual(dog.thresholds["graphHighRecallThreshold"], 0.01)
        let localization = TaxonomyLocalization(locale: "en", translations: ["dog": "Dog", "dog-synonyms": "Pooch|Puppy"], english: [:], availableLocales: ["en"])
        XCTAssertEqual(value.matching(query: "puppy", localization: localization).map(\.name), ["dog"])
        XCTAssertEqual(value.matching(query: "493").map(\.name), ["dog"])
        XCTAssertTrue(value.matching(query: "", network: 2).isEmpty)
        XCTAssertTrue(value.matching(query: "dog", indexed: false).isEmpty)
    }
    func testUnsupportedSourceAndBrokenGraphsAreRejected() {
        for text in [smallSource + "e:dog,canine\n", smallSource + "e:canine,dog\n", smallSource + "d:canine:missing\n", smallSource + "n:493,1,1,0.2,0.03,0.07,0.01,0.15,0.02,other\n", smallSource.replacingOccurrences(of: "0.2,", with: "nan,"), smallSource + "x:future\n"] {
            XCTAssertThrowsError(try SceneTaxonomyReader.decodeArchive(Data(text.utf8), source: source))
        }
    }
    func testMissingTranslationSentinelFallsBackWithoutInventedAliases() {
        let value = TaxonomyLocalization(locale: "ko", translations: ["dog": "NULL", "dog-synonyms": "NULL"], english: ["dog": "Dog", "dog-synonyms": "Dogs"], availableLocales: ["en", "ko"])
        XCTAssertEqual(value.label("dog"), "Dog"); XCTAssertEqual(value.synonyms("dog"), ["Dogs"]); XCTAssertTrue(value.usesEnglishFallback("dog"))
        XCTAssertEqual(value.label("unknown"), "unknown"); XCTAssertEqual(value.synonyms("unknown"), [])
    }
    func testSourceKindsKeepContentClassificationSeparate() {
        XCTAssertTrue(TaxonomySource.isSceneIndex(URL(fileURLWithPath: "/cache/PFSceneTaxonomyData.index")))
        XCTAssertTrue(TaxonomySource.isSceneIndex(URL(fileURLWithPath: "/cache/PFSceneTaxonomyData_99.index")))
        XCTAssertFalse(TaxonomySource.isSceneIndex(URL(fileURLWithPath: "/cache/PFContentClassificationTaxonomyData_5.index")))
        XCTAssertFalse(TaxonomySource.isSceneIndex(URL(fileURLWithPath: "/cache/PFSceneTaxonomyData_unknown.index")))
    }
    func testRealArchivesAndIndexesAgainstEveryRecoveredResearchRecord() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("research-notes/scene-taxonomy")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-cache/PFSceneTaxonomyData_99.index").path) else { throw XCTSkip("Taxonomy research capture unavailable") }
        let archiveURL = directory.appendingPathComponent("PFSceneTaxonomyData_99.bz2"), stored = try Data(contentsOf: archiveURL)
        let archive = try SceneTaxonomyReader.decodeArchive(SceneTaxonomyReader.decompress(stored), source: source, storedData: stored, budget: WorkBudget(seconds: 20))
        XCTAssertEqual(archive.concepts.count, 3515); XCTAssertEqual(archive.hierarchyEdges, 3333); XCTAssertEqual(archive.detectorLinks, 1531)
        XCTAssertEqual(archive.nodes["interior_room"]?.sceneID, 2147483653)
        for name in ["PFSceneTaxonomyData.index", "PFSceneTaxonomyData_99.index"] {
            let url = directory.appendingPathComponent("native-cache/" + name), data = try Data(contentsOf: url)
            let before = SHA256.hash(data: data)
            let value = try SceneTaxonomyReader.decodeIndex(data, source: TaxonomySource(url: url, isCache: true), budget: WorkBudget(seconds: 20))
            XCTAssertEqual(value.nodes.count, 3516); XCTAssertEqual(value.concepts.count, 3515); XCTAssertEqual(value.indexVersion, 6); XCTAssertEqual(value.checksumValid, true)
            XCTAssertEqual(value.hierarchyEdges, 3563); XCTAssertEqual(value.differences(from: archive), 0)
            let json = try JSONDecoder().decode(Projection.self, from: Data(contentsOf: directory.appendingPathComponent("index-" + name + ".json")))
            let expected = json.nodes
            XCTAssertEqual(value.declaredDigest, json.declaredDigest)
            for (name, node) in value.nodes {
                let row = try XCTUnwrap(expected[name])
                XCTAssertEqual(node.sceneID, row.sceneID)
                XCTAssertEqual(node.networkID, row.networkID)
                XCTAssertEqual(node.indexed, row.indexed)
                XCTAssertEqual(node.thresholds, row.thresholds)
                XCTAssertEqual(node.parents, row.parents); XCTAssertEqual(node.children, row.children); XCTAssertEqual(node.detectors, row.detectors)
            }
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), before)
            var corrupt = data; corrupt[1000] ^= 1
            XCTAssertThrowsError(try SceneTaxonomyReader.decodeIndex(corrupt, source: TaxonomySource(url: url, isCache: true)))
            XCTAssertThrowsError(try SceneTaxonomyReader.decodeIndex(data.prefix(128), source: TaxonomySource(url: url, isCache: true)))
        }
        let oldURL = directory.appendingPathComponent("PFSceneTaxonomyData_84.bz2")
        let old = try SceneTaxonomyReader.decodeArchive(SceneTaxonomyReader.decompress(Data(contentsOf: oldURL)), source: TaxonomySource(url: oldURL, isCache: false), budget: WorkBudget(seconds: 20))
        XCTAssertEqual(old.nodes.count, 2771); XCTAssertEqual(Set(archive.nodes.keys).subtracting(old.nodes.keys).count, 841)
        XCTAssertEqual(Set(old.nodes.keys).subtracting(archive.nodes.keys).count, 97)
    }
    func testCompressionRejectsTruncatedAndOversizedOutput() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("research-notes/scene-taxonomy")
        let url = directory.appendingPathComponent("PFSceneTaxonomyData_99.bz2")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Research archive unavailable") }
        let data = try Data(contentsOf: url)
        XCTAssertThrowsError(try SceneTaxonomyReader.decompress(data.prefix(64)))
        XCTAssertThrowsError(try SceneTaxonomyReader.decompress(data, maximum: 1024))
    }
    func testInstalledLocalizationAndExplicitFlagDisagreement() throws {
        guard FileManager.default.fileExists(atPath: SceneTaxonomyReader.resourceDirectory.appendingPathComponent("scenetaxonomy.loctable").path) else { throw XCTSkip("Installed taxonomy localization unavailable") }
        let labels = try SceneTaxonomyReader.localization(budget: WorkBudget(seconds: 15))
        XCTAssertEqual(labels.label("Q1349227"), "Academic Dress")
        XCTAssertEqual(labels.label("dog"), "Dog"); XCTAssertTrue(labels.synonyms("dog").contains("Puppy"))
        XCTAssertEqual(labels.searchable["blue_sky"], true)
    }
}
