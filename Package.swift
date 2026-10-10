// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaAnalysisExplorer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MediaAnalysisExplorer", targets: ["MediaAnalysisExplorer"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .systemLibrary(name: "CBZip2"),
        .target(name: "CAtlasSupport", publicHeadersPath: "include"),
        .target(name: "ExplorerCore", dependencies: ["CSQLite", "CBZip2", "CAtlasSupport"]),
        .executableTarget(name: "MediaAnalysisExplorer", dependencies: ["ExplorerCore"], resources: [.copy("Resources/Geography")]),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore", "CSQLite"])
    ]
)
