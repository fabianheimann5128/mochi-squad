// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MochiSquad",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .executableTarget(name: "MochiSquad", dependencies: ["SwiftTerm"], path: "Sources/MochiSquad"),
        .testTarget(name: "MochiSquadTests", dependencies: ["MochiSquad"], path: "Tests/MochiSquadTests"),
    ]
)
