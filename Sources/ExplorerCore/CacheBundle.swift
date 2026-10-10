import Foundation

public struct CacheBundle: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let files: [InventoryFile]
    public let buildLabel: String?
    public let cacheKey: String?
    public let targets: [String]
    public let sourceReferences: [String]
    public let declaredNames: [String]
    public let roles: [String: Int]
    public let purposes: [String]
    public let executionBackends: [String]
    public var summary: String {
        let purpose = purposes.isEmpty ? "Contains a compiled AI program and its supporting files." : purposes.joined(separator: " ")
        let execution = executionBackends.isEmpty ? "" : " Compute stages: " + executionBackends.joined(separator: " and ") + "."
        return purpose + execution
    }
    public var logicalBytes: Int64 { files.reduce(0) { $0 + $1.logicalBytes } }
    public var allocatedBytes: Int64? { files.allSatisfy { $0.allocatedBytes != nil } ? files.reduce(0) { $0 + ($1.allocatedBytes ?? 0) } : nil }
    public var modified: Date? { files.compactMap(\.modified).max() }
    public var title: String {
        if !declaredNames.isEmpty { return declaredNames.joined(separator: " · ") }
        if !sourceReferences.isEmpty {
            return sourceReferences.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }.sorted().joined(separator: " · ")
        }
        return "Variant " + String(url.deletingPathExtension().lastPathComponent.prefix(12))
    }
    public var description: String {
        let detail = roles.keys.sorted().map { "\(roles[$0]!) \($0)" }.joined(separator: " · ")
        return detail.isEmpty ? "Inventoried bundle contents" : detail
    }
    public func contains(_ file: InventoryFile) -> Bool { file.url.path.hasPrefix(url.path + "/") }
    public static func group(files: [InventoryFile], explanations: [String: CacheExplanation], root: URL) -> [Self] {
        var groups: [String: [InventoryFile]] = [:]
        let rootParts = root.standardizedFileURL.pathComponents
        for file in files {
            let parts = file.url.standardizedFileURL.pathComponents
            guard parts.starts(with: rootParts), parts.count > rootParts.count,
                  let first = parts.indices.dropFirst(rootParts.count).first(where: { parts[$0].hasSuffix(".bundle") }) else { continue }
            let path = NSString.path(withComponents: Array(parts.prefix(first + 1)))
            groups[path, default: []].append(file)
        }
        return groups.map { path, files in
            let url = URL(fileURLWithPath: path), parts = url.pathComponents
            let marker = parts.firstIndex(of: "com.apple.e5rt.e5bundlecache")
            let build = marker.flatMap { parts.indices.contains($0 + 1) ? parts[$0 + 1] : nil }
            let key = marker.flatMap { parts.indices.contains($0 + 2) ? parts[$0 + 2] : nil }
            var purposes: Set<String> = [], backends: Set<String> = []
            var targets: Set<String> = [], sources: Set<String> = [], names: Set<String> = [], roles: [String: Int] = [:]
            for file in files {
                let explanation = explanations[file.id] ?? CacheExplanation.describe(url: file.url, metadata: nil)
                sources.formUnion(explanation.sourceReferences)
                if let purpose = explanation.purpose { purposes.insert(purpose) }
                backends.formUnion(explanation.executionBackends)
                for item in explanation.dataObservations {
                    for prefix in ["Declared source model name: ", "Declared source container: "] where item.hasPrefix(prefix) {
                        names.insert(String(item.dropFirst(prefix.count)))
                    }
                }
                roles[explanation.role, default: 0] += 1
                let relative = file.url.pathComponents.dropFirst(parts.count)
                for component in relative where component.hasSuffix(".bundle") { targets.insert(component) }
            }
            return Self(url: url, files: files.sorted { $0.id < $1.id }, buildLabel: build, cacheKey: key, targets: targets.sorted(), sourceReferences: sources.sorted(), declaredNames: names.sorted(), roles: roles, purposes: purposes.sorted(), executionBackends: backends.sorted())
        }.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
