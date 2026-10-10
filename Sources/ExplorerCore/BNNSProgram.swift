import Foundation

public enum BNNSTensorDimension: Equatable, Sendable {
    case fixed(UInt64), dynamic
    public var display: String { switch self { case .fixed(let value): String(value); case .dynamic: "dynamic" } }
}

public struct BNNSBoundaryTensor: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let name: String
    public let role: String
    public let dataType: String
    public let dataTypeCode: UInt32
    public let dimensions: [BNNSTensorDimension]
    /// Strides in declared tensor-axis order, rather than BNNS descriptor order.
    public let strides: [UInt64?]?
    public var shape: String { "[" + dimensions.map(\.display).joined(separator: ", ") + "]" }
    public var strideDescription: String? { strides.map { "[" + $0.map { $0.map(String.init) ?? "dynamic" }.joined(separator: ", ") + "]" } }
}

public struct BNNSKernelCount: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let name: String?
    public let count: Int
    public var code: String { String(format: "0x%x", id) }
    public var displayName: String { name ?? "Unresolved kernel" }
}

public struct BNNSProgram: Sendable {
    public let function: String
    public let tensors: [BNNSBoundaryTensor]
    public let operations: [BNNSKernelCount]
    public let operationCount: Int
    public let serializedBytes: UInt64
    public let compiler: String?
    public var inputs: [BNNSBoundaryTensor] { tensors.filter { $0.role == "Input" } }
    public var outputs: [BNNSBoundaryTensor] { tensors.filter { $0.role == "Output" } }
    public var estimatedMetadataBytes: Int {
        256 + tensors.reduce(0) { $0 + $1.name.utf8.count + 256 } + operations.reduce(0) { $0 + ($1.name?.utf8.count ?? 0) + 64 }
    }
    public static let metadataLimit = 2 * 1024 * 1024
    public static let formatVersion = "0x50000"

    /// Known single-function layout validated against all nine captured programs
    /// and Apple's metadata getters on build 26A434. No native graph APIs run.
    public static func decode(_ data: Data, fileSize: Int64, compilerTrailer: Data? = nil, budget: WorkBudget = WorkBudget(seconds: 15)) throws -> Self {
        guard data.count <= metadataLimit, fileSize >= 200 else { throw ExplorerError("BNNS metadata exceeds the 2 MiB limit or the file is truncated") }
        let reader = Reader(bytes: Array(data))
        guard try reader.u32(0) == 0xd7dba027, try reader.u32(4) == 0x50000 else { throw ExplorerError("Unsupported BNNS signature/version") }
        let serialized = try reader.u64(8), trailerOffset = try reader.u64(16)
        guard serialized >= 200, serialized <= UInt64(fileSize), trailerOffset <= serialized else { throw ExplorerError("Invalid BNNS serialized extent") }
        guard try reader.u64(0x88) == 1 else { throw ExplorerError("Only the observed single-function BNNS format is supported") }
        let offsets = try [0x30, 0x38, 0x40, 0x48, 0x50, 0x58, 0x60, 0x68].map { try reader.offset($0) }
        guard offsets[0] >= 200, offsets == offsets.sorted(), UInt64(offsets[7]) <= trailerOffset else { throw ExplorerError("Invalid BNNS metadata section order") }
        let names = try reader.names(start: offsets[0], end: offsets[1], maximum: 1)
        guard names.count == 1, names[0].id == 0 else { throw ExplorerError("Invalid BNNS function declaration") }
        let arguments = try reader.names(start: offsets[1], end: offsets[2], maximum: 512)
        guard !arguments.isEmpty, Set(arguments.map(\.id)).count == arguments.count,
              Set(arguments.map(\.name)).count == arguments.count else { throw ExplorerError("Invalid or duplicate BNNS argument names") }
        let tensorCount = try reader.count(0xb0, maximum: 100_000)
        guard tensorCount == (offsets[5] - offsets[4]) / 48, (offsets[5] - offsets[4]) % 48 == 0 else { throw ExplorerError("Invalid BNNS tensor declaration table") }
        let namedIDs = Set(arguments.map(\.id))
        var declarations: [UInt64: (String, UInt32, [BNNSTensorDimension], [UInt64?]?)] = [:]
        for index in 0..<tensorCount {
            if index % 1024 == 0 { try budget.check() }
            let offset = offsets[4] + index * 48, identity = try reader.u64(offset)
            guard namedIDs.contains(identity) else { continue }
            guard declarations[identity] == nil else { throw ExplorerError("Duplicate BNNS tensor declaration") }
            let rank = Int(try reader.u32(offset + 20)), style = try reader.u32(offset + 28)
            guard rank <= 8 else { throw ExplorerError("Unsupported BNNS tensor rank") }
            let relative = try reader.u64(offset + 32), shapeBytes = offsets[7] - offsets[6]
            let required = 8 + rank * 8
            guard required <= shapeBytes, relative <= UInt64(shapeBytes - required) else { throw ExplorerError("BNNS tensor shape lies outside metadata") }
            let blob = offsets[6] + Int(relative), type = try reader.u32(blob)
            var dimensions: [BNNSTensorDimension] = []
            for axis in 0..<rank {
                let raw = try reader.u64(blob + 8 + axis * 8)
                switch raw {
                case 0x8000000000000000, UInt64.max: dimensions.append(.dynamic)
                case 0...UInt64(Int64.max): dimensions.append(.fixed(raw))
                default: throw ExplorerError("Unsupported BNNS symbolic dimension")
                }
            }
            var strides: [UInt64?]?
            if style == 0 {
                var values = [UInt64?](repeating: nil, count: rank), stride: UInt64? = 1
                for axis in (0..<rank).reversed() {
                    values[axis] = stride
                    if axis > 0 {
                        if case .fixed(let dimension) = dimensions[axis], let value = stride {
                            let product = value.multipliedReportingOverflow(by: dimension)
                            stride = product.overflow ? nil : product.partialValue
                        } else { stride = nil }
                    }
                }
                strides = values
            } else if style == 1 || style == 2 {
                let required = 8 + rank * 16
                guard required <= shapeBytes, relative <= UInt64(shapeBytes - required) else { throw ExplorerError("BNNS tensor strides lie outside metadata") }
                strides = try (0..<rank).map { axis -> UInt64? in
                    let raw = try reader.u64(blob + 8 + rank * 8 + axis * 8)
                    return raw <= UInt64(Int64.max) ? raw : nil
                }
            }
            declarations[identity] = (typeName(type), type, dimensions, strides)
        }
        let tensors = try arguments.map { argument -> BNNSBoundaryTensor in
            guard let declaration = declarations[argument.id], let role = [UInt64(1): "Output", UInt64(2): "Input"][argument.id >> 60] else { throw ExplorerError("Unresolved BNNS boundary tensor declaration") }
            return BNNSBoundaryTensor(id: argument.id, name: argument.name, role: role, dataType: declaration.0, dataTypeCode: declaration.1, dimensions: declaration.2, strides: declaration.3)
        }
        let operationCount = try reader.count(0xa8, maximum: 100_000)
        guard operationCount == (offsets[3] - offsets[2]) / 64, (offsets[3] - offsets[2]) % 64 == 0 else { throw ExplorerError("Invalid BNNS operation table") }
        var histogram: [UInt32: Int] = [:]
        for index in 0..<operationCount {
            if index % 1024 == 0 { try budget.check() }
            histogram[try reader.u32(offsets[2] + index * 64), default: 0] += 1
        }
        let operations = histogram.map { BNNSKernelCount(id: $0.key, name: kernelNames[$0.key], count: $0.value) }
            .sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
        var compiler: String?
        if let compilerTrailer, serialized - trailerOffset <= 4096, UInt64(compilerTrailer.count) == serialized - trailerOffset {
            let prefix = Data("__CompilerVersion".utf8)
            if let range = compilerTrailer.range(of: prefix), range.lowerBound == 32 {
                let suffix = compilerTrailer[range.upperBound...].prefix { $0 != 0 }
                if !suffix.isEmpty, suffix.allSatisfy({ (0x20...0x7e).contains($0) }) { compiler = String(data: suffix, encoding: .ascii) }
            }
        }
        return Self(function: names[0].name, tensors: tensors, operations: operations, operationCount: operationCount, serializedBytes: serialized, compiler: compiler)
    }

    /// Bounds-check the small compiler footer before Inventory seeks to it.
    static func trailerRange(_ data: Data, fileSize: Int64) throws -> (offset: UInt64, count: Int)? {
        guard fileSize >= 200 else { return nil }
        let reader = Reader(bytes: Array(data.prefix(200)))
        guard try reader.u32(0) == 0xd7dba027, try reader.u32(4) == 0x50000 else { return nil }
        let end = try reader.u64(8), start = try reader.u64(16)
        guard start <= end, end <= UInt64(fileSize), end - start <= 4096 else { return nil }
        return (start, Int(end - start))
    }

    private static func typeName(_ code: UInt32) -> String {
        [UInt32(0x10010): "Float16", 0x10020: "Float32", 0x18010: "BFloat16", 0x20020: "Int32", 0x20040: "Int64", 0x40010: "UInt16", 0x40020: "UInt32"][code] ?? String(format: "Unknown (0x%x)", code)
    }

    private struct Reader {
        let bytes: [UInt8]
        func span(_ offset: Int, _ count: Int) throws -> ArraySlice<UInt8> {
            guard offset >= 0, count >= 0, offset <= bytes.count, count <= bytes.count - offset else { throw ExplorerError("BNNS metadata is truncated or outside the 2 MiB read limit") }
            return bytes[offset..<offset + count]
        }
        func u64(_ offset: Int) throws -> UInt64 { try span(offset, 8).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) } }
        func u32(_ offset: Int) throws -> UInt32 { try span(offset, 4).enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } }
        func offset(_ field: Int) throws -> Int {
            let raw = try u64(field)
            guard raw <= UInt64(bytes.count) else { throw ExplorerError("BNNS metadata offset exceeds the read limit") }
            return Int(raw)
        }
        func count(_ field: Int, maximum: Int) throws -> Int {
            let raw = try u64(field)
            guard raw <= UInt64(maximum) else { throw ExplorerError("BNNS record count exceeds the supported limit") }
            return Int(raw)
        }
        func names(start: Int, end: Int, maximum: Int) throws -> [(id: UInt64, name: String)] {
            var offset = start, result: [(id: UInt64, name: String)] = []
            while offset < end {
                guard result.count < maximum, end - offset >= 17 else { throw ExplorerError("Invalid BNNS name table") }
                let identity = try u64(offset), length = try u64(offset + 8)
                guard length > 0, length <= 4096, length < UInt64(end - offset - 16) else { throw ExplorerError("Invalid BNNS name length") }
                let raw = try span(offset + 16, Int(length))
                guard !raw.contains(0), bytes[offset + 16 + Int(length)] == 0,
                      let name = String(bytes: raw, encoding: .utf8), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ExplorerError("Invalid BNNS tensor name") }
                let next = (offset + 16 + Int(length) + 1 + 7) & ~7
                guard next <= end else { throw ExplorerError("BNNS name overlaps the next section") }
                result.append((identity, name)); offset = next
            }
            return result
        }
    }

    /// IDs verified against build 26A434 getters; unknown IDs stay numeric.
    private static let kernelNames: [UInt32: String] = [
        0x300: "KERNEL_CAST_GENERIC", 0x1002: "KERNEL_GATHER_LUT", 0x200: "KERNEL_COPY_GENERIC",
        0xb36: "KERNEL_MATMUL_MLA2", 0x700: "KERNEL_ELEMENTWISE_ACTIVATION", 0x101: "KERNEL_ARITHMETIC_BINARY",
        0x801: "KERNEL_REDUCE_FP_SUM", 0x202: "KERNEL_COPY_MLA2", 0x20f: "KERNEL_COPY_ALIAS_DYNAMIC",
        0x102: "KERNEL_ARITHMETIC_BINARY_DYNAMIC", 0x304: "KERNEL_CAST_DYNAMIC",
        0x1000022: "KERNEL_ARITHMETIC_MUL_FP16_DYNAMIC_MLA2", 0x225: "KERNEL_COPY_DYNAMIC_MLA_OR_NEON",
        0xf01: "KERNEL_RELATIONAL_DYNAMIC", 0x106: "KERNEL_ARITHMETIC_TERNARY_DYNAMIC", 0x1000: "KERNEL_GATHER",
        0x407: "KERNEL_TRANSPOSE2D_MLA2_DYNAMIC", 0x1501: "KERNEL_MISC_PREFIX_SUM",
        0x1000006: "KERNEL_ARITHMETIC_VADD_FP16_MLA2", 0x406: "KERNEL_TRANSPOSE2D_MLA2",
        0x12009: "KERNEL_CONV_KERNELPOOL_FACETIME_VOICE_ISOLATION_MLA2_Mx1x64OC_x_Mx1x8IC_FP16",
        0x908: "KERNEL_LAYERNORM_V2", 0x1000018: "KERNEL_ARITHMETIC_VSMUL_FP16_MLA2", 0x1200: "KERNEL_SOFTMAX",
        0x100: "KERNEL_ARITHMETIC_UNARY", 0x1000016: "KERNEL_ARITHMETIC_VMUL_FP16_MLA2",
        0x1fd8: "KERNEL_KBIT_DEQUANTIZE_ASYMMETRIC_UINT8_INT8", 0x505: "KERNEL_CONV_MLA"
    ]
}
