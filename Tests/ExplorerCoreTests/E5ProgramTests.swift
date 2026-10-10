import XCTest
import CryptoKit
@testable import ExplorerCore

final class E5ProgramTests: XCTestCase {
    private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/E5") }
    private func data(_ name: String = "06.e5") throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    private func word(_ data: Data, _ offset: Int, width: Int = 4) -> UInt64 { data[offset..<offset+width].enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) } }
    private func write(_ data: inout Data, _ offset: Int, _ value: UInt64, width: Int = 4) { for i in 0..<width { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
    private func field(_ data: Data, table: Int, index: Int) -> Int {
        let vt = table - Int(Int32(bitPattern: UInt32(word(data, table))))
        return table + Int(word(data, vt + 4 + index * 2, width: 2))
    }
    private func reference(_ data: Data, _ field: Int) -> Int { field + Int(word(data, field)) }

    func testAllTwentyManifestsMatchIndependentResearchEvidence() throws {
        let records = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: fixtures.appendingPathComponent("expected.json")))
        var functionCount = 0, operationCount = 0, operandCount = 0
        for record in records {
            let bytes = try data(record.file), actual = try E5Program.decode(bytes)
            XCTAssertEqual(bytes.count, record.bytes)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), record.sha256)
            XCTAssertEqual(actual.buildInfo, record.buildInfo)
            XCTAssertEqual(actual.functions.count, record.functions.count)
            for (a, e) in zip(actual.functions, record.functions) {
                XCTAssertEqual(a.id, e.symbol); XCTAssertEqual(a.name, e.name)
                XCTAssertEqual(a.inputs, e.inputs); XCTAssertEqual(a.outputs, e.outputs); XCTAssertEqual(a.inouts, e.inouts)
                XCTAssertEqual(a.blocks.map(\.operations), e.blocks.map(\.operations))
                XCTAssertEqual(a.blocks.map(\.inputs), e.blocks.map(\.inputs)); XCTAssertEqual(a.blocks.map(\.outputs), e.blocks.map(\.outputs))
            }
            XCTAssertEqual(actual.operands.count, record.tensors.count + record.surfaces.count)
            for e in record.tensors {
                let a = try XCTUnwrap(actual.operand(e.symbol))
                XCTAssertEqual(a.name, e.name); XCTAssertEqual(a.dataType, e.dataType)
                XCTAssertEqual(a.dimensions, e.shape); XCTAssertEqual(a.byteStrides, e.byteStrides)
                XCTAssertEqual(a.descriptorBytes, e.descriptorBytes); XCTAssertEqual(a.section, e.section)
                XCTAssertEqual(a.allocationOffset, e.allocationOffset)
            }
            for e in record.surfaces {
                let a = try XCTUnwrap(actual.operand(e.symbol))
                XCTAssertEqual(a.name, e.name); XCTAssertEqual(a.dataType, "Surface"); XCTAssertNil(a.dimensions)
            }
            XCTAssertEqual(actual.operations.count, record.operations.count)
            for (a, e) in zip(actual.operations, record.operations) {
                XCTAssertEqual(a.id, e.symbol); XCTAssertEqual(a.name, e.name); XCTAssertEqual(a.opcode, e.opcode)
                XCTAssertEqual(a.inputs, e.inputs); XCTAssertEqual(a.outputs, e.outputs); XCTAssertEqual(a.inouts, e.inouts)
                XCTAssertEqual(a.companionPath, e.attributes.programPath); XCTAssertEqual(a.entryName, e.attributes.entryName)
            }
            XCTAssertEqual(actual.sections.count, record.sections.count)
            for (a, e) in zip(actual.sections, record.sections) {
                XCTAssertEqual(a.name, e.name); XCTAssertEqual(a.declaredBytes, e.declaredBytes); XCTAssertEqual(a.hasData, e.hasData)
            }
            functionCount += actual.functions.count; operationCount += actual.operations.count; operandCount += actual.operands.count
        }
        XCTAssertEqual(records.count, 20); XCTAssertEqual(functionCount, 107); XCTAssertEqual(operationCount, 233); XCTAssertEqual(operandCount, 477)
    }
    func testDeclaredIdentityAndContextShapesDoNotInventNames() throws {
        XCTAssertEqual(try E5Program.decode(data("13.e5")).declaredModelName, "md8-text-encoder")
        XCTAssertEqual(try E5Program.decode(data("08.e5")).declaredModelName, "ObjectDetectionModel")
        let audio = try E5Program.decode(data("17.e5"))
        XCTAssertNil(audio.declaredModelName)
        XCTAssertEqual(audio.operand(audio.functions[0].inputs[0])?.name, "specgram")
        XCTAssertFalse(CacheExplanation.describe(url: URL(fileURLWithPath: "/cache/H13G.e5"), metadata: nil, e5: audio).observations.contains { $0.contains("Spectrogram embedding") })
        let sequence = try E5Program.decode(data("07.e5"))
        XCTAssertEqual(sequence.functions.compactMap { sequence.operand($0.inputs[0])?.dimensions?.first }, [1, 5, 20])
        XCTAssertEqual(try E5Program.decode(data("02.e5")).functions.count, 22)
    }
    func testBundleSummaryUsesActualComputeStagesAndKeepsUnknownModelUnnamed() throws {
        let url = URL(fileURLWithPath: "/cache/caption.bundle/H13G.bundle/H13G.e5")
        let program = try E5Program.decode(data("06.e5"))
        let explanation = CacheExplanation.describe(url: url, metadata: nil, e5: program)
        XCTAssertEqual(explanation.executionBackends, ["CPU", "Neural Engine"])
        XCTAssertEqual(explanation.purpose, "Decodes visual features into caption word scores.")
        let file = InventoryFile(url: url, logicalBytes: 100, allocatedBytes: nil, modified: nil, labels: "")
        let bundle = try XCTUnwrap(CacheBundle.group(files: [file], explanations: [file.id: explanation], root: URL(fileURLWithPath: "/cache")).first)
        XCTAssertTrue(bundle.summary.contains("CPU and Neural Engine"))
        XCTAssertFalse(bundle.summary.contains("GPU"))
        let audio = try E5Program.decode(data("17.e5"))
        let audioExplanation = CacheExplanation.describe(url: url, metadata: nil, e5: audio)
        XCTAssertNil(audio.declaredModelName)
        XCTAssertEqual(audioExplanation.purpose, "Extracts audio features from a spectrogram.")
        let uninspected = CacheExplanation.describe(url: url, metadata: nil)
        XCTAssertNil(uninspected.purpose)
        XCTAssertTrue(uninspected.executionBackends.isEmpty)
    }
    func testCorruptTruncatedAndOversizedMetadataIsRejected() throws {
        let original = try data()
        for count in [0, 4, 32, original.count/2, original.count-1] { XCTAssertThrowsError(try E5Program.decode(Data(original.prefix(count)))) }
        XCTAssertThrowsError(try E5Program.decode(Data(repeating: 0, count: E5Program.byteLimit+1)))
        let root = Int(word(original, 0)), header = reference(original, field(original, table: root, index: 0))
        let sections = reference(original, field(original, table: root, index: 1)), symtab = reference(original, field(original, table: root, index: 2))
        let symbols = reference(original, field(original, table: symtab, index: 0))
        let symbol = reference(original, symbols+4), section = reference(original, sections+4)
        for (offset, value, width) in [(0, UInt64(UInt32.max), 4), (root, UInt64(Int32.max), 4),
            (field(original, table: header, index: 0), 0, 2), (field(original, table: header, index: 2), 9, 2),
            (sections, UInt64(UInt32.max), 4), (symbols, UInt64(UInt32.max), 4),
            (field(original, table: symbol, index: 2), UInt64(UInt32.max), 4),
            (reference(original, field(original, table: section, index: 0)), UInt64(UInt32.max), 4),
            (field(original, table: symbol, index: 5), UInt64.max, 8)] {
            var broken = original; write(&broken, offset, value, width: width)
            XCTAssertThrowsError(try E5Program.decode(broken), "field \(offset)")
        }
    }
    func testUnknownOpcodeIsPreservedAndReferencesAreStillValidated() throws {
        var bytes = try data()
        let root = Int(word(bytes, 0)), symtab = reference(bytes, field(bytes, table: root, index: 2))
        let symbols = reference(bytes, field(bytes, table: symtab, index: 0)), sections = reference(bytes, field(bytes, table: root, index: 1))
        let payloads = reference(bytes, field(bytes, table: root, index: 3))
        let kernelSymbol = reference(bytes, symbols + 4 + 7*4)
        let section = reference(bytes, sections + 4 + Int(word(bytes, field(bytes, table: kernelSymbol, index: 2)))*4)
        let payloadWrapper = reference(bytes, payloads + 4 + Int(word(bytes, field(bytes, table: section, index: 4)))*4)
        let payload = reference(bytes, field(bytes, table: payloadWrapper, index: 0))+4
        let record = payload + Int(word(bytes, field(bytes, table: kernelSymbol, index: 4), width: 8))
        let kernel = reference(bytes, record+4)
        write(&bytes, field(bytes, table: kernel, index: 0), 0xdead)
        let unknown = try E5Program.decode(bytes)
        XCTAssertEqual(unknown.operations.first?.kind, "Unknown operation (57005)")
        XCTAssertNil(unknown.operations.first?.companionPath)
        let frame = reference(bytes, field(bytes, table: kernel, index: 1))
        let inputs = reference(bytes, field(bytes, table: frame, index: 1))
        write(&bytes, inputs+4, UInt64.max, width: 8)
        XCTAssertThrowsError(try E5Program.decode(bytes))
    }
    func testCompanionsStayWithinTheManifestTargetAndInventory() {
        let manifest = URL(fileURLWithPath: "/cache/H13G.bundle/H13G.e5"), path = "main/main_bnns/bnns_program.bnnsir"
        let expected = "/cache/H13G.bundle/" + path
        XCTAssertEqual(E5Program.companionURL(path, manifest: manifest, inventoriedPaths: [expected])?.path, expected)
        XCTAssertNil(E5Program.companionURL(path, manifest: manifest, inventoriedPaths: []))
        for path in ["../other/file", "/etc/passwd", "main/../file", "main//file", "main/./file", "main\\file", "file\0"] {
            XCTAssertNil(E5Program.companionURL(path, manifest: manifest, inventoriedPaths: [expected]))
        }
    }
    func testFileInspectionKeepsEvidenceForUnsupportedFilesAndHonorsCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("H13G.e5")
        try data().write(to: file)
        let inspection = try Inventory.inspect(url: file, hash: false, budget: WorkBudget())
        XCTAssertEqual(inspection.e5?.operations.count, 5); XCTAssertNil(inspection.metadataIssue)
        try Data([0x10,0,0,0]).write(to: file)
        let broken = try Inventory.inspect(url: file, hash: false, budget: WorkBudget())
        XCTAssertNil(broken.e5); XCTAssertNotNil(broken.metadataIssue); XCTAssertEqual(broken.signature, "10 00 00 00")
        let budget = WorkBudget(); budget.cancel()
        XCTAssertThrowsError(try E5Program.decode(data(), budget: budget))
    }
    private struct Expected: Decodable {
        let file: String, sha256: String; let bytes: Int; let buildInfo: [String: String]
        let functions: [Function]; let tensors: [Tensor]; let surfaces: [Surface]; let operations: [Operation]; let sections: [Section]
        struct Function: Decodable { let symbol: Int; let name: String; let inputs, outputs, inouts: [Int]; let blocks: [Block] }
        struct Block: Decodable { let operations, inputs, outputs: [Int] }
        struct Tensor: Decodable { let symbol: Int; let name, dataType, section: String; let shape, byteStrides: [UInt64]; let descriptorBytes, allocationOffset: UInt64 }
        struct Surface: Decodable { let symbol: Int; let name: String }
        struct Operation: Decodable { let symbol: Int; let name: String; let opcode: UInt32; let inputs, outputs, inouts: [Int]; let attributes: Attributes }
        struct Attributes: Decodable { let programPath, entryName: String? }
        struct Section: Decodable { let name: String; let declaredBytes: UInt64; let hasData: Bool }
    }
}
