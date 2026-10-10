import Foundation

public struct CacheExplanation: Sendable {
    public let role: String
    public let observations: [String]
    public let sourceReferences: [String]
    public let pathFields: [String: String]
    public let bundleDirectory: URL?
    public let summary: String
    public let purpose: String?
    public let executionBackends: [String]
    public var dataObservations: [String] { observations }

    public static func describe(url: URL, metadata: String?, bnns: BNNSProgram? = nil, e5: E5Program? = nil) -> Self {
        let name = url.lastPathComponent
        let role: String
        var observations: [String] = []; var sourceReferences: Set<String> = []
        if name.hasSuffix(".bnnsir") {
            role = "BNNS compiled-program artifact"
            if let bnns {
                observations.append("Stored function: " + bnns.function)
                observations.append("\(bnns.inputs.count) inputs · \(bnns.outputs.count) outputs · \(bnns.operationCount) compiled operations")
                observations.append("Named boundary tensors: " + bnns.tensors.map(\.name).joined(separator: ", "))
            }
        } else if name.hasSuffix(".espresso.net") {
            role = "Espresso graph description"
        } else if name.hasSuffix(".espresso.shape") {
            role = "Tensor-shape description"
        } else if name.hasSuffix(".espresso.weights") {
            role = "Espresso weight storage"
        } else if TaxonomySource.isSceneIndex(url) {
            role = "Scene-taxonomy index"
            observations.append("Category identifiers, networks, indexed flags, thresholds, hierarchy and detector links. Open the taxonomy browser to decode and validate this file.")
        } else if name.hasSuffix(".anehash") {
            role = "ANE compilation hash"
        } else if name.hasSuffix(".milhash") {
            role = "MIL source hash"
        } else if url.pathExtension == "e5" {
            role = "E5 compiled-program manifest"
            if let e5 {
                if let name = e5.declaredModelName { observations.append("Declared source container: " + name) }
                else {
                    let inputs = Set(e5.functions.flatMap(\.inputs))
                    observations.append("Declared inputs: " + Array(Set(e5.operands.filter { inputs.contains($0.id) }.map(\.name))).sorted().joined(separator: ", "))
                }
                if let path = e5.declaredSource { observations.append("Declared source path: " + path) }
                observations.append("\(e5.functions.count) functions · \(e5.operations.count) stored operations")
                observations.append("Stored function names: " + e5.functions.map(\.name).joined(separator: ", "))
                observations.append("Named operands: " + Array(Set(e5.operands.map(\.name))).sorted().joined(separator: ", "))
            }
        } else if url.pathExtension == "json" {
            role = "JSON metadata"
        } else if url.pathExtension == "plist" {
            role = "Property-list metadata"
        } else if name == "PFSceneGeographyData.index" {
            role = "Geographic scene atlas"
            observations.append("Static geographic cells, two popularity variants and weighted scene-group memberships. Open Geography to decode this exact index and browse its map.")
        } else { role = "Cached file · purpose unresolved" }
        let components = url.pathComponents
        var fields: [String: String] = [:]; var bundle: URL?
        if let i = components.firstIndex(of: "com.apple.e5rt.e5bundlecache"), components.count > i + 3 {
            let labels = ["Build label", "Opaque cache key", "Variant bundle", "Target label", "Function/context label"]
            for (offset, label) in labels.enumerated() where components.indices.contains(i + offset + 1) {
                fields[label] = components[i + offset + 1]
            }
            if components[i + 3].hasSuffix(".bundle") {
                bundle = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(i + 4))))
            }
        }
        if let metadata, metadata.utf8.count <= 256 * 1024,
           let object = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any] {
            if let analyses = object["analyses"] as? [String: Any],
               let debug = analyses["N8Espresso23analysis_debug_metadataE"] as? [String: Any],
               let framework = debug["com.apple.EspressoFramework"] as? [String: Any] {
                if let path = framework["input-file-path"] as? String, path.hasPrefix("/System/Library/"), path.hasSuffix("model.espresso.net") {
                    sourceReferences.insert(path)
                }
                if let name = debug["name"] as? String, !name.isEmpty { observations.append("Declared source model name: " + name) }
                if let compiled = framework["on-device-compilation"] as? String, ["true", "false"].contains(compiled) {
                    observations.append("Declared on-device compilation: " + compiled)
                } else if let compiled = framework["on-device-compilation"] as? NSNumber {
                    observations.append("Declared on-device compilation: " + (compiled.boolValue ? "true" : "false"))
                }
            }
            if let layers = object["layers"] as? [[String: Any]] {
                if let version = object["format_version"] as? NSNumber { observations.append("Declared graph format version: " + version.stringValue) }
                let sourcePattern = try? NSRegularExpression(pattern: #"(/System/Library/[^\n]+?/model\.mil)(?::[0-9]+:[0-9]+)?"#)
                for layer in layers {
                    if let debug = layer["debug_info"] as? String, let sourcePattern {
                        let text = debug as NSString
                        for match in sourcePattern.matches(in: debug, range: NSRange(location: 0, length: text.length)) {
                            sourceReferences.insert(text.substring(with: match.range(at: 1)))
                        }
                    }
                }
                let types = Set(layers.compactMap { $0["type"] as? String }).sorted()
                observations.append("Stored layer operations: " + types.prefix(20).joined(separator: ", "))
                for layer in layers where layer["type"] as? String == "non_maximum_suppression" {
                    let keys = ["score_threshold", "iou_threshold", "max_boxes", "per_class_suppression"]
                    let values = keys.compactMap { key in layer[key].map { "\(key)=\($0)" } }
                    observations.append("NMS post-processing: " + values.joined(separator: ", "))
                }
                if layers.count == 3, types == ["cast", "softmax_nd"], sourceReferences.contains(where: { $0.contains("VideoCaptioning") }) {
                    observations.append("Caption probability post-processing: cast → softmax → cast.")
                }
                let outputs = layers.filter { (($0["attributes"] as? [String: Any])?["is_output"] as? NSNumber)?.boolValue == true }
                    .compactMap { $0["top"] as? String }
                if !outputs.isEmpty { observations.append("Declared output names: " + outputs.prefix(20).joined(separator: ", ")) }
                if let storage = object["storage"] as? String { observations.append("Referenced weight file: " + storage) }
            }
            if let shapes = object["layer_shapes"] as? [String: Any] {
                for key in shapes.keys.sorted().prefix(16) {
                    if let shape = shapes[key] as? [String: Any] {
                        let dimensions = shape.keys.sorted().map { "\($0)=\(shape[$0]!)" }.joined(separator: ", ")
                        observations.append("\(key): \(dimensions)")
                    }
                }
            }
        }
        if let path = e5?.declaredSource, path.hasPrefix("/System/Library/"), ["net", "mil"].contains(URL(fileURLWithPath: path).pathExtension) { sourceReferences.insert(path) }
        let identity = (sourceReferences.sorted() + [e5?.declaredSource ?? ""] + observations.filter { $0.hasPrefix("Declared source") }).joined(separator: " ").lowercased()
        let tensors = Set((bnns?.tensors.map(\.name) ?? []) + (e5?.operands.map(\.name) ?? []))
        let purpose: String?
        switch identity {
        case let value where value.contains("md8-token-encoder"): purpose = "Converts text tokens into embeddings for system search."
        case let value where value.contains("md8-text-encoder"): purpose = "Encodes text for semantic search."
        case let value where value.contains("mubb_md8"): purpose = "Extracts visual embeddings from images and video."
        case let value where value.contains("natureworldmodel"): purpose = "Recognizes plants, animals, and pet breeds for Visual Look Up."
        case let value where value.contains("objectdetectionmodel"): purpose = "Detects objects and scores their categories for Visual Look Up."
        case let value where value.contains("unifiedmodel") && value.contains("visuallookup"): purpose = "Classifies images and extracts embeddings for Visual Look Up."
        case let value where value.contains("cr_td_model"): purpose = "Finds text regions in images."
        case let value where value.contains("cr_orientation_model"): purpose = "Determines text orientation for recognition."
        case let value where value.contains("cr_tr_model_arabic"): purpose = "Recognizes Arabic text."
        case let value where value.contains("cr_tr_model_devanagari"): purpose = "Recognizes Devanagari text."
        case let value where value.contains("cr_tr_model_latincyrillic"): purpose = "Recognizes Latin and Cyrillic text."
        case let value where value.contains("caption") && value.contains("decoder"): purpose = "Decodes visual features into caption word scores."
        default:
            if tensors.contains("fused_embedding") { purpose = "Combines audio and visual embeddings." }
            else if tensors.contains("captioning_decoder_word_probs") { purpose = "Decodes visual features into caption word scores." }
            else if tensors.contains("image_encoder_head_out") { purpose = "Transforms visual features for caption generation." }
            else if tensors.contains("specgram") { purpose = "Extracts audio features from a spectrogram." }
            else { purpose = nil }
        }
        var backends: Set<String> = []
        for operation in e5?.operations ?? [] {
            switch operation.opcode {
            case 1: backends.insert("Neural Engine")
            case 2, 12: backends.insert("CPU")
            default: break
            }
        }
        if name.hasSuffix(".bnnsir") { backends.insert("CPU") }
        let summary: String
        switch role {
        case "BNNS compiled-program artifact": summary = "Compiled AI computation for the CPU, including its tensor interface and kernels."
        case "E5 compiled-program manifest": summary = "AI program plan connecting compute stages, tensors, and compiled files."
        case "Espresso graph description": summary = "Neural-network operations and their connections, read by Apple's Espresso runtime."
        case "Tensor-shape description": summary = "Dimensions of the tensors used by the accompanying neural network."
        case "Espresso weight storage": summary = "Learned parameters for the accompanying neural network."
        case "Scene-taxonomy index": summary = "Categories Photos can recognize, with labels, relationships, and score thresholds."
        case "Geographic scene atlas": summary = "Geographic cells and scene groups used for location-based scene information."
        case "ANE compilation hash": summary = "Identifies a compiled Neural Engine artifact."
        case "MIL source hash": summary = "Identifies the model's intermediate representation used during compilation."
        case "JSON metadata", "Property-list metadata": summary = "Supporting cache metadata."
        default: summary = "Cached file with no recognized format."
        }
        return Self(role: role, observations: observations, sourceReferences: sourceReferences.sorted(), pathFields: fields, bundleDirectory: bundle, summary: summary, purpose: purpose, executionBackends: backends.sorted())
    }
}
