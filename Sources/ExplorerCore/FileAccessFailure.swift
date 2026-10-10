import Foundation
import Darwin

/// A failed read is not an empty folder. Preserve the error chain and distinguish
/// permissions from missing paths, so recovery instructions match the failure.
public struct FileAccessFailure: Sendable {
    public let path: String
    public let detail: String
    public let isPermissionDenied: Bool
    public init(error: Error, url: URL) {
        path = url.path
        var current: NSError? = error as NSError
        var denied = false
        var descriptions: [String] = []
        for _ in 0..<8 {
            guard let value = current else { break }
            denied = denied || (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoPermissionError)
                || (value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code))
            descriptions.append("\(value.domain) \(value.code): \(value.localizedDescription)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        isPermissionDenied = denied
        detail = descriptions.joined(separator: "\n")
    }
}
