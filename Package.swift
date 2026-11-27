// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MochiSquad",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "MochiSquad",
            dependencies: ["SwiftTerm", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MochiSquad",
            // Sparkle.framework lies in Contents/Frameworks of the app bundle (see install.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MochiSquadTests", dependencies: ["MochiSquad"], path: "Tests/MochiSquadTests"),
    ]
)
