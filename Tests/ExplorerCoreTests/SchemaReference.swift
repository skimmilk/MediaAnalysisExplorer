import Foundation
@testable import ExplorerCore

/// Captured/installed matching 26A434 schema reference, not an assumption about
/// every future database revision. Projected names/types only, no archive code.
public enum SchemaReference {
    public static func project(_ data: Data) throws -> [String: String] {
        guard data.count <= 256 * 1024, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let entities = root["entities"] as? [String: [String: Any]] else { throw ExplorerError("Unsupported schema reference") }
        let types = [100: "Int16", 200: "Int32", 300: "Int64", 400: "Decimal", 500: "Double", 600: "Float", 700: "String", 800: "Boolean", 900: "Date", 1000: "Binary data", 1800: "Transformable"]
        var notes: [String: String] = [:]
        for (entity, description) in entities {
            guard let properties = description["properties"] as? [String: [String: Any]] else { continue }
            for (name, property) in properties {
                var components = ["26A434 schema reference: \(entity).\(name)"]
                if let type = property["NSAttributeType"] as? Int { components.append(types[type] ?? "Private type \(type)") }
                if let optional = property["NSIsOptional"] as? Bool { components.append(optional ? "optional" : "required") }
                if let transformer = property["NSValueTransformerName"] as? String { components.append("transformer " + transformer) }
                if let destination = property["NSDestinationEntity"] as? String { components.append("relationship to " + destination) }
                if let inverse = property["NSInverseRelationship"] as? String { components.append("inverse " + inverse) }
                notes["Z" + entity.uppercased() + ":Z" + name.uppercased()] = components.joined(separator: " · ")
            }
        }
        return notes
    }
}
