import SwiftUI
import ExplorerCore

struct E5ProgramView: View {
    let program: E5Program
    let manifest: URL
    let files: [InventoryFile]
    let openFile: (InventoryFile) -> Void
    @State private var selectedFunction: Int
    @State private var expandedStages: Set<Int>
    @State private var technicalExpanded: Bool
    init(program: E5Program, manifest: URL, files: [InventoryFile], initiallySelectedFunction: Int? = nil, initiallyExpanded: Bool = false, openFile: @escaping (InventoryFile) -> Void) {
        self.program = program; self.manifest = manifest; self.files = files; self.openFile = openFile
        _selectedFunction = State(initialValue: initiallySelectedFunction ?? program.functions.first!.id)
        _expandedStages = State(initialValue: initiallyExpanded ? Set(program.operations.map(\.id)) : [])
        _technicalExpanded = State(initialValue: initiallyExpanded)
    }
    private var function: E5Function { program.functions.first { $0.id == selectedFunction } ?? program.functions[0] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("E5 Program").font(.headline)
            Text("Connects CPU and Neural Engine stages into a compiled AI program.").font(.caption).foregroundStyle(.secondary)
            MetadataFields(fields: ["Source model": program.declaredModelName ?? "Not named", "Functions": String(program.functions.count), "Stored operations": String(program.operations.count)])
            if let source = program.declaredSource {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source path").font(.caption.weight(.medium))
                    Text(source).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if program.functions.count > 1 {
                Picker("Function / context", selection: $selectedFunction) {
                    ForEach(program.functions) { Text($0.name).tag($0.id) }
                }.pickerStyle(.menu)
            } else { Text("Function · " + function.name).font(.subheadline.monospaced()).textSelection(.enabled) }
            Text("External inputs & outputs").font(.headline)
            operandSection("Inputs", ids: function.inputs)
            operandSection("Outputs", ids: function.outputs)
            if !function.inouts.isEmpty { operandSection("Inputs / outputs", ids: function.inouts) }
            Text("Compute Stages").font(.headline)
            Text("Expand a stage to see its tensors and compiled file.").font(.caption).foregroundStyle(.secondary)
            ForEach(function.blocks) { block in
                VStack(alignment: .leading, spacing: 10) {
                    if function.blocks.count > 1 { Text("Block \(block.id + 1)").font(.subheadline.weight(.medium)) }
                    ForEach(Array(block.operations.enumerated()), id: \.offset) { index, id in
                        if let operation = program.operation(id) {
                            DisclosureGroup(isExpanded: Binding(get: { expandedStages.contains(id) }, set: { if $0 { expandedStages.insert(id) } else { expandedStages.remove(id) } })) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(operation.name).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    operandSection("Inputs", ids: operation.inputs)
                                    operandSection("Outputs", ids: operation.outputs)
                                    if !operation.inouts.isEmpty { operandSection("Inputs / outputs", ids: operation.inouts) }
                                    if let path = operation.companionPath {
                                        Text("Companion · " + path).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                        Text("Entry · " + (operation.entryName.flatMap { $0.isEmpty ? nil : $0 } ?? "Stored empty / unspecified")).font(.caption.monospaced()).textSelection(.enabled)
                                        if let file = companion(operation) {
                                            Button("Open Compiled Artifact", systemImage: "doc.text.magnifyingglass") { openFile(file) }.controlSize(.small)
                                        } else { Text("Companion unavailable in this inventory").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }.padding(.top, 8)
                            } label: { Text("\(index + 1). \(operation.kind)").font(.subheadline.weight(.medium)) }
                        }
                    }
                }
            }
            DisclosureGroup("Technical details", isExpanded: $technicalExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    MetadataFields(fields: program.buildInfo.filter { $0.key != "input-file-path" }.merging(["Raw target": String(format: "0x%x", program.target), "Header": "0xe4e5 / 0 / 2"]) { old, _ in old })
                    Text("Tensor storage · byte strides").font(.subheadline.weight(.medium))
                    Text("In declared axis order. These allocations can differ from a BNNS program's element strides.").font(.caption).foregroundStyle(.secondary)
                    ForEach(referencedOperands) { operand in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(operand.name).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            MetadataFields(fields: ["Byte strides": operand.strides ?? "Surface format unresolved", "Descriptor bytes": operand.descriptorBytes.map(String.init) ?? "Unavailable", "Section": operand.section, "Allocation offset": String(operand.allocationOffset)])
                        }
                    }
                    Text("Allocation sections").font(.subheadline.weight(.medium))
                    ForEach(program.sections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.name).font(.caption.monospaced()).textSelection(.enabled)
                            Text("\(section.declaredBytes) declared bytes · \(section.hasData ? "Embedded payload" : "Allocation only")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.top, 8)
            }
        }.onChange(of: selectedFunction) { _, _ in expandedStages = [] }
    }
    private var referencedOperands: [E5Operand] {
        let operations = function.blocks.flatMap(\.operations).compactMap { program.operation($0) }
        let ids = Set(function.inputs + function.outputs + function.inouts + operations.flatMap { $0.inputs + $0.outputs + $0.inouts })
        return program.operands.filter { ids.contains($0.id) }
    }
    private func companion(_ operation: E5Operation) -> InventoryFile? {
        guard let path = operation.companionPath, let url = E5Program.companionURL(path, manifest: manifest, inventoriedPaths: Set(files.map(\.id))) else { return nil }
        return files.first { $0.id == url.path }
    }
    private func operandSection(_ title: String, ids: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if ids.isEmpty { Text("None declared").font(.caption).foregroundStyle(.secondary) }
            ForEach(ids, id: \.self) { id in
                if let operand = program.operand(id) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(operand.name).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text(operand.dataType + " · " + operand.shape).font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
