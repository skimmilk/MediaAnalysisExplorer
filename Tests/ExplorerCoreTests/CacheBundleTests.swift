import XCTest
@testable import ExplorerCore

final class CacheBundleTests: XCTestCase {
    private func file(_ path: String, size: Int64 = 10, allocation: Int64? = 16) -> InventoryFile {
        InventoryFile(url: URL(fileURLWithPath: path), logicalBytes: size, allocatedBytes: allocation, modified: nil, labels: "")
    }
    func testNestedTargetsGroupedOnceWithoutPrefixCollisions() {
        let root = URL(fileURLWithPath: "/cache"), base = "/cache/com.apple.e5rt.e5bundlecache/26A434/key/variant.bundle"
        let files = [file(base + "/H13G.bundle/main/model.bnnsir"), file(base + "/CPU.bundle/main/model.espresso.net", size: 20, allocation: nil), file(base + "-other/ignored.bnnsir"), file("/cache-outside/x.bundle/outside.net"), file("/cache/PFSceneTaxonomyData_99.index")]
        let bundles = CacheBundle.group(files: files, explanations: [:], root: root)
        XCTAssertEqual(bundles.count, 1)
        let bundle = bundles[0]; XCTAssertEqual(bundle.files.count, 2); XCTAssertEqual(bundle.logicalBytes, 30); XCTAssertNil(bundle.allocatedBytes)
        XCTAssertEqual(bundle.targets, ["CPU.bundle", "H13G.bundle"]); XCTAssertEqual(bundle.buildLabel, "26A434"); XCTAssertEqual(bundle.cacheKey, "key")
        XCTAssertFalse(bundle.contains(files[2])); XCTAssertFalse(bundle.contains(files[3]))
    }
    func testDescriptionsUseGraphEvidenceAndNeverOpaqueKeysAsModelNames() {
        let root = URL(fileURLWithPath: "/cache"), path = "/cache/build/key/opaque.bundle/model.espresso.net"
        let item = file(path)
        let graph = #"{"analyses":{"N8Espresso23analysis_debug_metadataE":{"name":"Observed graph","com.apple.EspressoFramework":{"input-file-path":"/System/Library/PrivateFrameworks/Example.framework/model.espresso.net"}}}}"#
        let explanation = CacheExplanation.describe(url: item.url, metadata: graph)
        let bundle = CacheBundle.group(files: [item], explanations: [item.id: explanation], root: root)[0]
        XCTAssertEqual(bundle.title, "Observed graph"); XCTAssertEqual(bundle.sourceReferences.count, 1)
        XCTAssertEqual(bundle.roles["Espresso graph description"], 1)
        XCTAssertEqual(CacheExplanation.describe(url: URL(fileURLWithPath: "/cache/PFSceneTaxonomyData.index"), metadata: nil).role, "Scene-taxonomy index")
    }
}
