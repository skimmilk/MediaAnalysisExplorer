import XCTest
@testable import ExplorerCore

final class BNNSProgramTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/BNNS")
    }
    private func data(_ name: String = "08.bnnsir") throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name + ".metadata")) }
    private func word(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<offset+8].enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    private func write(_ data: inout Data, _ offset: Int, _ value: UInt64, bytes: Int = 8) {
        for i in 0..<bytes { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
    private func decode(_ data: Data, size: Int64 = 131_072) throws -> BNNSProgram { try BNNSProgram.decode(data, fileSize: size) }

    func testAllNineMetadataPrefixesMatchIndependentAppleGetterEvidence() throws {
        let expected = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: fixtures.appendingPathComponent("expected.json")))
        var tensors = 0, operations = 0
        for file in expected {
            let program = try BNNSProgram.decode(data(file.file), fileSize: file.fileSize,
                compilerTrailer: Data(contentsOf: fixtures.appendingPathComponent(file.file + ".footer")))
            XCTAssertEqual(program.function, file.function, file.file)
            XCTAssertEqual(program.compiler, file.compiler, file.file)
            XCTAssertEqual(program.operationCount, file.operationCount, file.file)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: program.operations.map { ($0.displayName, $0.count) }), file.operations, file.file)
            XCTAssertEqual(program.tensors.count, file.tensors.count, file.file)
            for (actual, expected) in zip(program.tensors, file.tensors) {
                XCTAssertEqual(actual.name, expected.name)
                XCTAssertEqual(actual.role, expected.role)
                XCTAssertEqual(actual.dataType, expected.type)
                XCTAssertEqual(actual.dimensions, expected.shape.map { $0 == 0 ? .dynamic : .fixed($0) })
                XCTAssertEqual(actual.strides, expected.strides.map(Optional.some))
            }
            tensors += program.tensors.count; operations += program.operationCount
        }
        XCTAssertEqual(tensors, 33); XCTAssertEqual(operations, 2112)
    }

    func testDynamicDimensionsPaddedStridesAndTypeNamesAreNotGuessedFromTensorNames() throws {
        let dynamic = try decode(data("03.bnnsir"), size: 25_690_112)
        XCTAssertEqual(dynamic.inputs.first?.shape, "[dynamic, 128]")
        let padded = try decode(data("00.bnnsir"), size: 6_537_216)
        let encoder = try XCTUnwrap(padded.inputs.first)
        XCTAssertEqual(encoder.shape, "[1, 512, 1, 122]")
        XCTAssertEqual(encoder.strideDescription, "[65536, 128, 128, 1]")
        XCTAssertEqual(padded.outputs.last?.dataType, "Float16")
        XCTAssertTrue(padded.outputs.last?.name.contains("uint16") == true)
    }

    func testTruncatedMetadataAndOverflowingOffsetsNeverProducePartialPrograms() throws {
        let original = try data()
        for size in [0, 7, 63, 199, 343, 447, 895, original.count - 1] {
            XCTAssertThrowsError(try decode(Data(original.prefix(size))), "prefix \(size)")
        }
        for (offset, value) in [(0, UInt64(0)), (8, UInt64.max), (16, UInt64.max), (0x40, UInt64.max), (0xa8, UInt64.max), (0xb0, UInt64.max), (0x88, UInt64(2))] {
            var broken = original; write(&broken, offset, value)
            XCTAssertThrowsError(try decode(broken), "field \(offset)")
        }
        var tooLarge = original; tooLarge.append(Data(repeating: 0, count: BNNSProgram.metadataLimit))
        XCTAssertThrowsError(try decode(tooLarge))
        XCTAssertThrowsError(try BNNSProgram.decode(original, fileSize: -1))
    }

    func testMalformedNamesShapesAndOperationTableAreRejected() throws {
        let original = try data(), names = Int(word(original, 0x38)), tensors = Int(word(original, 0x50))
        for (offset, value, width) in [(names+8, UInt64.max, 8), (names+16, UInt64(0), 1), (tensors+20, UInt64(9), 4), (tensors+32, UInt64.max, 8), (0xa8, UInt64(2), 8)] {
            var broken = original; write(&broken, offset, value, bytes: width)
            XCTAssertThrowsError(try decode(broken), "field \(offset)")
        }
        var version = original; write(&version, 4, 0x60000, bytes: 4)
        XCTAssertThrowsError(try decode(version))
        var symbol = original; write(&symbol, Int(word(original, 0x60))+8, 0x8000000000000001)
        XCTAssertThrowsError(try decode(symbol))
    }

    func testUnknownKernelAndElementTypeStayExplicitWithoutInventedLabels() throws {
        var unknown = try data()
        write(&unknown, Int(word(unknown, 0x40)), 0xdeadbeef, bytes: 4)
        write(&unknown, Int(word(unknown, 0x60)), 0x123456, bytes: 4)
        let program = try decode(unknown)
        XCTAssertNil(program.operations.first?.name)
        XCTAssertEqual(program.operations.first?.code, "0xdeadbeef")
        XCTAssertEqual(program.outputs.first?.dataType, "Unknown (0x123456)")
    }

    func testFileInspectorReadsMetadataAndFooterWithoutRequiringModelWeights() throws {
        let prefix = try data(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("program.bnnsir")
        var sparse = Data(repeating: 0, count: 131_072)
        sparse.replaceSubrange(0..<prefix.count, with: prefix)
        let footer = try Data(contentsOf: fixtures.appendingPathComponent("08.bnnsir.footer")), start = Int(word(prefix, 16))
        sparse.replaceSubrange(start..<start+footer.count, with: footer); try sparse.write(to: file)
        let inspection = try Inventory.inspect(url: file, hash: false, budget: WorkBudget())
        XCTAssertEqual(inspection.bnns?.inputs.first?.name, "specgram")
        XCTAssertEqual(inspection.bnns?.compiler, "BasicNeuralNetworkSubroutines-2212.1.1~15")
        XCTAssertNil(inspection.metadataIssue)
        XCTAssertNil(inspection.sha256)
        let explanation = CacheExplanation.describe(url: file, metadata: nil, bnns: inspection.bnns)
        XCTAssertTrue(explanation.dataObservations.contains { $0.contains("specgram") })
        XCTAssertTrue(explanation.sourceReferences.isEmpty)
        try Data([0x27, 0xa0, 0xdb, 0xd7]).write(to: file)
        let unsupported = try Inventory.inspect(url: file, hash: false, budget: WorkBudget())
        XCTAssertNil(unsupported.bnns)
        XCTAssertNotNil(unsupported.metadataIssue)
        XCTAssertEqual(unsupported.signature, "27 a0 db d7")
    }

    func testCancelledDecodeRespectsWorkBudget() throws {
        let budget = WorkBudget(); budget.cancel()
        XCTAssertThrowsError(try BNNSProgram.decode(data(), fileSize: 131_072, budget: budget))
    }

    private struct Expected: Decodable {
        let file: String, function: String, compiler: String
        let fileSize: Int64
        let operationCount: Int
        let operations: [String: Int]
        let tensors: [Tensor]
        struct Tensor: Decodable {
            let name: String, role: String, type: String
            let shape: [UInt64], strides: [UInt64]
        }
    }
}
