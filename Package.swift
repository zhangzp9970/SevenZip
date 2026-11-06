// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SevenZip",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SevenZip", targets: ["SevenZip"])],
    targets: [
        .target(name: "SevenZipBridge", path: "BridgeAPI", publicHeadersPath: "include"),
        .target(name: "ArchiveCore", dependencies: ["SevenZipBridge"]),
        .executableTarget(name: "SevenZip", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"])
    ]
)
