import Foundation

public struct E5Operand: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let section: String
    public let allocationOffset: UInt64
    public let descriptorKind: UInt8
    public let typeKind: UInt8?
    public let typeSize: UInt32?
    public let dimensions: [UInt64]?
    public let byteStrides: [UInt64]?
    public let descriptorBytes: UInt64?
    public var dataType: String {
        guard let typeKind, let typeSize else { return "Surface" }
        switch (typeKind, typeSize) {
        case (4, 3): return "Float16"
        case (4, 6): return "Float32"
        case (1, 6): return "Int32"
        default: return "Unknown (\(typeKind), \(typeSize))"
        }
    }
    public var shape: String { dimensions.map { "[" + $0.map(String.init).joined(separator: ", ") + "]" } ?? "Surface format unresolved" }
    public var strides: String? { byteStrides.map { "[" + $0.map(String.init).joined(separator: ", ") + "]" } }
}
public struct E5Operation: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let opcode: UInt32
    public let inputs: [Int]
    public let outputs: [Int]
    public let inouts: [Int]
    public let companionPath: String?
    public let entryName: String?
    public var kind: String {
        switch opcode { case 1: "ANE"; case 2: "Espresso CPU"; case 3: "Cast"; case 12: "BNNS CPU"; default: "Unknown operation (\(opcode))" }
    }
}
public struct E5Block: Identifiable, Equatable, Sendable {
    public let id: Int
    public let operations: [Int]
    public let inputs: [Int]
    public let outputs: [Int]
    public let inouts: [Int]
}
public struct E5Function: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let inputs: [Int]
    public let outputs: [Int]
    public let inouts: [Int]
    public let blocks: [E5Block]
}
public struct E5Section: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let declaredBytes: UInt64
    public let hasData: Bool
    public let type: UInt32
    public let permissions: UInt32
}
public struct E5Program: Sendable {
    public let functions: [E5Function]
    public let operands: [E5Operand]
    public let operations: [E5Operation]
    public let sections: [E5Section]
    public let buildInfo: [String: String]
    public let target: UInt32
    public static let byteLimit = 1024 * 1024
    public var declaredSource: String? { buildInfo["input-file-path"].flatMap { $0.isEmpty ? nil : $0 } }
    /// Exact source container basename, only when an installed model is declared.
    /// Opaque cache hashes and tensor-based role guesses are never model names.
    public var declaredModelName: String? {
        guard let source = declaredSource, source.hasPrefix("/System/Library/"),
              source.hasSuffix("/model.mil") || source.hasSuffix("/model.espresso.net") else { return nil }
        let container = URL(fileURLWithPath: source).deletingLastPathComponent().lastPathComponent
        for suffix in [".mlmodelc.bundle", ".mlmodelc"] where container.hasSuffix(suffix) { return String(container.dropLast(suffix.count)) }
        return container
    }
    public func operand(_ id: Int) -> E5Operand? { operands.first { $0.id == id } }
    public func operation(_ id: Int) -> E5Operation? { operations.first { $0.id == id } }
    public var estimatedMetadataBytes: Int {
        512 + operands.reduce(0) { $0 + $1.name.utf8.count + $1.section.utf8.count + 384 }
        + operations.reduce(0) { $0 + $1.name.utf8.count + ($1.companionPath?.utf8.count ?? 0) + ($1.entryName?.utf8.count ?? 0) + 256 + ($1.inputs.count + $1.outputs.count + $1.inouts.count) * 8 }
        + functions.reduce(0) { $0 + $1.name.utf8.count + 256 + ($1.inputs.count + $1.outputs.count + $1.inouts.count) * 8 + $1.blocks.reduce(0) { $0 + 128 + ($1.operations.count + $1.inputs.count + $1.outputs.count + $1.inouts.count) * 8 } }
        + sections.reduce(0) { $0 + $1.name.utf8.count + 128 } + buildInfo.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 64 }
    }
    /// Resolves only an inventoried regular companion below this target directory.
    /// A serialized path never grants permission to open an arbitrary filesystem path.
    public static func companionURL(_ path: String, manifest: URL, inventoriedPaths: Set<String>) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let base = manifest.deletingLastPathComponent().standardizedFileURL
        let url = base.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), inventoriedPaths.contains(url.path) else { return nil }
        return url
    }

    public static func decode(_ data: Data, budget: WorkBudget = WorkBudget()) throws -> Self {
        try budget.check()
        guard data.count >= 8, data.count <= byteLimit else { throw ExplorerError("E5 file is truncated or exceeds the 1 MiB limit") }
        let source = Storage(bytes: Array(data), budget: budget), reader = Reader(source: source, lower: 0, end: data.count)
        let root = try reader.root()
        guard root.fields.count == 4 else { throw ExplorerError("Unsupported E5 root schema") }
        let header = try reader.table(root.ref(0))
        guard try header.scalar(0, width: 2) == 0xe4e5, try header.scalar(1, width: 2) == 0,
              try header.scalar(2, width: 2) == 2, try header.scalar(3) == 0x8103 else { throw ExplorerError("Unsupported E5 header, version or target") }
        let payloads = try root.tables(3, maximum: 256).map { try $0.byteRange(0) }
        let sectionTables = try root.tables(1, maximum: 256)
        guard !sectionTables.isEmpty else { throw ExplorerError("Missing E5 sections") }
        var sections: [E5Section] = [], sectionData: [Reader?] = []
        for (id, table) in sectionTables.enumerated() {
            let flag = try table.scalar(5, width: 1)
            guard flag <= 1 else { throw ExplorerError("Invalid E5 stored-section flag") }
            let section = try E5Section(id: id, name: table.requiredString(0), declaredBytes: table.scalar(3, width: 8), hasData: flag == 1, type: UInt32(table.scalar(1)), permissions: UInt32(table.scalar(2)))
            var payload: Reader?
            if section.hasData {
                let index = try table.scalar(4)
                guard index < payloads.count else { throw ExplorerError("Invalid E5 section data index") }
                let range = payloads[Int(index)]
                guard UInt64(range.count) == section.declaredBytes else { throw ExplorerError("E5 section length mismatch") }
                payload = Reader(source: source, lower: range.lowerBound, end: range.upperBound)
            }
            sections.append(section); sectionData.append(payload)
        }
        guard Set(sections.map(\.name)).count == sections.count,
              let descriptorIndex = sections.firstIndex(where: { $0.name == "__sym_desc__" }),
              let descriptors = sectionData[descriptorIndex] else { throw ExplorerError("Missing or duplicate E5 sections") }
        struct Symbol {
            let id: Int; let name: String; let type: UInt32; let section: Int; let offset: UInt64; let descriptor: UInt64
        }
        let symbolTables = try reader.table(root.ref(2)).tables(0, maximum: 8192)
        guard !symbolTables.isEmpty else { throw ExplorerError("Missing E5 symbols") }
        let symbols = try symbolTables.enumerated().map { id, t -> Symbol in
            let section = try t.scalar(2), offset = try t.scalar(4, width: 8)
            guard section < sections.count, offset <= sections[Int(section)].declaredBytes else { throw ExplorerError("E5 symbol lies outside its section") }
            return try Symbol(id: id, name: t.requiredString(0), type: UInt32(t.scalar(1)), section: Int(section), offset: offset, descriptor: t.scalar(5, width: 8))
        }
        func record(_ symbol: Symbol) throws -> Table {
            guard let section = sectionData[symbol.section] else { throw ExplorerError("E5 symbol has no stored payload") }
            return try section.record(symbol.offset).root(prefixed: true)
        }
        var operands: [E5Operand] = []
        for symbol in symbols where symbol.type == 1 {
            let descriptor = try descriptors.record(symbol.descriptor).root(prefixed: true)
            let kind = UInt8(try descriptor.scalar(0, width: 1)), tensor = try descriptor.reader.table(descriptor.ref(1))
            guard kind == 1 || kind == 2 else { throw ExplorerError("Unsupported E5 operand descriptor") }
            var typeKind: UInt8?, typeSize: UInt32?, dimensions: [UInt64]?, strides: [UInt64]?, size: UInt64?
            if kind == 1 {
                let type = try tensor.reader.table(tensor.ref(0))
                typeKind = UInt8(try type.scalar(0, width: 1)); typeSize = UInt32(try type.scalar(1))
                dimensions = try tensor.vector(1, width: 8, maximum: 8); strides = try tensor.vector(2, width: 8, maximum: 8)
                guard dimensions?.count == strides?.count else { throw ExplorerError("E5 tensor rank and strides disagree") }
                size = try tensor.scalar(3, width: 8)
            }
            operands.append(E5Operand(id: symbol.id, name: symbol.name, section: sections[symbol.section].name, allocationOffset: symbol.offset,
                descriptorKind: kind, typeKind: typeKind, typeSize: typeSize, dimensions: dimensions, byteStrides: strides, descriptorBytes: size))
        }
        let operandIDs = Set(operands.map(\.id))
        func ids(_ table: Table, _ field: Int, operandsOnly: Bool = true) throws -> [Int] {
            let raw = try table.vector(field, width: 8, maximum: 8192)
            guard raw.allSatisfy({ $0 < symbols.count }) else { throw ExplorerError("Invalid E5 symbol reference") }
            let values = raw.map(Int.init)
            guard !operandsOnly || values.allSatisfy({ operandIDs.contains($0) }) else { throw ExplorerError("E5 interface references a non-operand") }
            return values
        }
        var operations: [E5Operation] = [], functions: [E5Function] = []
        for symbol in symbols {
            if symbol.type == 2 {
                let kernel = try record(symbol), opcode = UInt32(try kernel.scalar(0))
                let frame = try kernel.reader.table(kernel.ref(1)), attributeID = try frame.scalar(0, width: 8)
                guard attributeID < symbols.count else { throw ExplorerError("Invalid E5 operation attributes") }
                let attribute = symbols[Int(attributeID)]
                guard attribute.type == 3, attribute.name == symbol.name + "__op_attrs" else { throw ExplorerError("E5 operation attribute reference mismatch") }
                let attributes = try record(attribute)
                var path: String?, entry: String?
                if opcode == 12 {
                    guard try attributes.scalar(0, width: 1) == 2 else { throw ExplorerError("Unsupported E5 BNNS program reference") }
                    path = try attributes.string(1); entry = try attributes.string(2)
                } else if opcode == 1 || opcode == 2 { path = try attributes.string(0); entry = try attributes.string(1) }
                operations.append(try E5Operation(id: symbol.id, name: symbol.name, opcode: opcode, inputs: ids(frame, 1), outputs: ids(frame, 2), inouts: ids(frame, 3), companionPath: path, entryName: entry))
            } else if symbol.type == 0 {
                let fn = try record(symbol)
                let blocks = try fn.tables(2, maximum: 512).enumerated().map { id, block -> E5Block in
                    let operations = try ids(block, 0, operandsOnly: false)
                    guard operations.allSatisfy({ symbols[$0].type == 2 }) else { throw ExplorerError("E5 block references a non-operation") }
                    return try E5Block(id: id, operations: operations, inputs: ids(block, 1), outputs: ids(block, 2), inouts: ids(block, 3))
                }
                functions.append(try E5Function(id: symbol.id, name: symbol.name, inputs: ids(fn, 0), outputs: ids(fn, 1), inouts: ids(fn, 4), blocks: blocks))
            }
        }
        guard !functions.isEmpty, functions.count <= 512, Set(functions.map(\.name)).count == functions.count,
              let buildSymbol = symbols.first(where: { $0.name == "build_info" }) else { throw ExplorerError("Missing or duplicate E5 function/build metadata") }
        var buildInfo: [String: String] = [:]
        for pair in try record(buildSymbol).tables(0, maximum: 64) {
            let key = try pair.requiredString(0), value = try pair.string(1) ?? ""
            guard buildInfo[key] == nil else { throw ExplorerError("Duplicate E5 build metadata key") }
            buildInfo[key] = value
        }
        try budget.check()
        return Self(functions: functions, operands: operands, operations: operations, sections: sections, buildInfo: buildInfo, target: 0x8103)
    }

    private final class Storage {
        let bytes: [UInt8]; let budget: WorkBudget; var remaining = 1_000_000
        init(bytes: [UInt8], budget: WorkBudget) { self.bytes = bytes; self.budget = budget }
        func spend(_ count: Int = 1) throws {
            guard count >= 0, count <= remaining else { throw ExplorerError("E5 metadata work limit exceeded") }
            remaining -= count
            if count > 256 || remaining % 256 == 0 { try budget.check() }
        }
    }
    private struct Reader {
        let source: Storage; let lower: Int; let end: Int
        func span(_ offset: Int, _ count: Int) throws -> Range<Int> {
            try source.spend()
            guard offset >= lower, offset <= end, count >= 0, count <= end - offset else { throw ExplorerError("E5 metadata is truncated or out of bounds") }
            return offset..<offset + count
        }
        func number(_ offset: Int, width: Int = 4) throws -> UInt64 {
            try span(offset, width).enumerated().reduce(0) { $0 | UInt64(source.bytes[$1.element]) << ($1.offset * 8) }
        }
        func reference(_ offset: Int) throws -> Int {
            let delta = try number(offset)
            guard delta >= 4, delta <= end - offset else { throw ExplorerError("Invalid E5 forward reference") }
            let target = offset + Int(delta); _ = try span(target, 4); return target
        }
        func root(prefixed: Bool = false) throws -> Table {
            if prefixed { guard try number(lower) == end - lower - 4 else { throw ExplorerError("E5 record length mismatch") } }
            return try table(reference(lower + (prefixed ? 4 : 0)))
        }
        func record(_ offset: UInt64) throws -> Reader {
            guard offset <= end - lower else { throw ExplorerError("Invalid E5 serialized record offset") }
            let start = lower + Int(offset), length = try number(start)
            guard length <= end - start - 4 else { throw ExplorerError("Invalid E5 serialized record extent") }
            return Reader(source: source, lower: start, end: start + 4 + Int(length))
        }
        func table(_ offset: Int) throws -> Table {
            let delta = Int64(Int32(bitPattern: UInt32(try number(offset))))
            let vtableRaw = Int64(offset) - delta
            guard vtableRaw >= lower, vtableRaw < end else { throw ExplorerError("Invalid E5 vtable reference") }
            let vtable = Int(vtableRaw), size = Int(try number(vtable, width: 2)), objectSize = Int(try number(vtable + 2, width: 2))
            guard size >= 4, size <= 128, size % 2 == 0, objectSize >= 4 else { throw ExplorerError("Invalid E5 table extent") }
            _ = try span(vtable, size); _ = try span(offset, objectSize)
            let fields = try stride(from: 4, to: size, by: 2).map { Int(try number(vtable + $0, width: 2)) }
            guard fields.allSatisfy({ $0 == 0 || ($0 >= 4 && $0 < objectSize) }) else { throw ExplorerError("E5 field lies outside its table") }
            return Table(reader: self, offset: offset, fields: fields, size: objectSize)
        }
        func vector(_ offset: Int, width: Int, maximum: Int, references: Bool = false) throws -> [UInt64] {
            let count = try number(offset)
            guard count <= maximum else { throw ExplorerError("E5 vector exceeds its count limit") }
            try source.spend(Int(count)); _ = try span(offset + 4, Int(count) * width)
            return try (0..<Int(count)).map { references ? UInt64(try reference(offset + 4 + $0 * width)) : try number(offset + 4 + $0 * width, width: width) }
        }
        func string(_ offset: Int) throws -> String {
            let count = try number(offset)
            guard count <= 4096 else { throw ExplorerError("E5 string exceeds its length limit") }
            let range = try span(offset + 4, Int(count))
            guard try number(offset + 4 + Int(count), width: 1) == 0,
                  !source.bytes[range].contains(0), let value = String(bytes: source.bytes[range], encoding: .utf8) else { throw ExplorerError("Invalid E5 string encoding/terminator") }
            return value
        }
    }
    private struct Table {
        let reader: Reader; let offset: Int; let fields: [Int]; let size: Int
        func field(_ index: Int, width: Int) throws -> Int? {
            let relative = index < fields.count ? fields[index] : 0
            guard relative != 0 else { return nil }
            guard width <= size - relative else { throw ExplorerError("Invalid E5 field width") }
            return offset + relative
        }
        func scalar(_ index: Int, width: Int = 4) throws -> UInt64 { try field(index, width: width).map { try reader.number($0, width: width) } ?? 0 }
        func ref(_ index: Int) throws -> Int {
            guard let field = try field(index, width: 4) else { throw ExplorerError("Missing required E5 reference") }
            return try reader.reference(field)
        }
        func string(_ index: Int) throws -> String? { try field(index, width: 4).map { try reader.string(reader.reference($0)) } }
        func requiredString(_ index: Int) throws -> String {
            guard let value = try string(index), !value.isEmpty else { throw ExplorerError("Missing E5 name") }; return value
        }
        func vector(_ index: Int, width: Int, maximum: Int, references: Bool = false) throws -> [UInt64] {
            guard let field = try field(index, width: 4) else { return [] }
            return try reader.vector(reader.reference(field), width: width, maximum: maximum, references: references)
        }
        func tables(_ index: Int, maximum: Int) throws -> [Table] { try vector(index, width: 4, maximum: maximum, references: true).map { try reader.table(Int($0)) } }
        func byteRange(_ index: Int) throws -> Range<Int> {
            let vector = try ref(index), size = try reader.number(vector)
            guard size <= E5Program.byteLimit else { throw ExplorerError("E5 payload exceeds size limit") }
            return try reader.span(vector + 4, Int(size))
        }
    }
}
