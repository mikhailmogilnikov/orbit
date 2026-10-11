// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OrbitKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OrbitKit", targets: ["OrbitKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/STTextView", from: "2.4.1"),
        .package(url: "https://github.com/krzyzanowskim/STTextView-Plugin-Neon", revision: "d568bf9"),
        // Same pins as STTextView-Plugin-Neon; used directly by SyntaxHighlightPlugin.
        .package(url: "https://github.com/kylemacomber/Neon", revision: "ce8d252"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", "1.20.0"..<"1.99.0"),
    ],
    targets: [
        .target(name: "OrbitACP"),
        .target(name: "OrbitAPI"),
        .target(name: "OrbitUI", dependencies: ["OrbitAPI"], resources: [.copy("Resources/OrbitMark.svg")]),
        .target(name: "OrbitExplorer", dependencies: ["OrbitAPI", "OrbitUI"]),
        .target(
            name: "OrbitEditor",
            dependencies: [
                "OrbitAPI", "OrbitUI",
                .product(name: "STTextView", package: "STTextView"),
                .product(name: "STTextView-Plugin-Neon", package: "STTextView-Plugin-Neon"),
                .product(name: "Neon", package: "Neon"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            ]
        ),
        .target(name: "OrbitReview", dependencies: ["OrbitAPI", "OrbitUI"]),
        .target(name: "OrbitSearch", dependencies: ["OrbitAPI", "OrbitUI"]),
        .target(name: "OrbitGit", dependencies: ["OrbitAPI", "OrbitUI", "OrbitACP"]),
        .target(
            name: "OrbitTerminal",
            dependencies: ["OrbitAPI", "OrbitUI", "OrbitACP", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .target(name: "OrbitAgents", dependencies: ["OrbitAPI", "OrbitUI", "OrbitACP"]),
        .target(
            name: "OrbitKit",
            dependencies: ["OrbitAPI", "OrbitUI", "OrbitExplorer", "OrbitEditor", "OrbitReview", "OrbitSearch", "OrbitGit", "OrbitTerminal", "OrbitAgents"]
        ),
        .testTarget(name: "OrbitKitTests", dependencies: ["OrbitAPI", "OrbitACP", "OrbitSearch", "OrbitTerminal", "OrbitGit", "OrbitAgents", "OrbitUI"]),
    ]
)
