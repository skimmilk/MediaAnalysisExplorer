import SwiftUI
import ExplorerCore

struct BNNSProgramView: View {
    let program: BNNSProgram
    @State private var operationsExpanded = false
    @State private var stridesExpanded = false
    init(program: BNNSProgram, initiallyExpanded: Bool = false) {
        self.program = program
        _operationsExpanded = State(initialValue: initiallyExpanded)
        _stridesExpanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CPU Program").font(.headline)
            Text("Inputs, outputs, and compiled CPU kernels.").font(.caption).foregroundStyle(.secondary)
            MetadataFields(fields: ["Function": program.function, "Format version": BNNSProgram.formatVersion,
                "Compiler": program.compiler ?? "Not recovered", "Compiled operations": String(program.operationCount),
                "Inputs / outputs": "\(program.inputs.count) / \(program.outputs.count)"])
            Text("Inputs & Outputs").font(.headline)
            tensorSection("Inputs", tensors: program.inputs)
            tensorSection("Outputs", tensors: program.outputs)
            DisclosureGroup("Storage strides", isExpanded: $stridesExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Elements per step, in the same axis order as each declared shape. Padding can make strides differ from logical dimensions.").font(.caption).foregroundStyle(.secondary)
                    ForEach(program.tensors) { tensor in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tensor.name).font(.caption.monospaced()).textSelection(.enabled)
                            Text(tensor.strideDescription ?? "Unavailable for this stored layout").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }.padding(.top, 8)
            }
            DisclosureGroup("Operations · \(program.operationCount) compiled kernels", isExpanded: $operationsExpanded) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("Compiled operations used by this CPU program.").font(.caption).foregroundStyle(.secondary)
                    ForEach(program.operations) { operation in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(operation.displayName).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                Text(operation.code).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text("×\(operation.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.top, 8)
            }
        }
    }
    private func tensorSection(_ title: String, tensors: [BNNSBoundaryTensor]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if tensors.isEmpty { Text("None declared").font(.caption).foregroundStyle(.secondary) }
            ForEach(tensors) { tensor in
                VStack(alignment: .leading, spacing: 4) {
                    Text(tensor.name).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(alignment: .top, spacing: 12) {
                        Text(tensor.dataType).foregroundStyle(.teal)
                        Text(tensor.shape).monospaced().textSelection(.enabled)
                    }.font(.caption)
                    if tensor.dimensions.contains(.dynamic) {
                        Text("Dynamic dimension · size is selected at runtime").font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
