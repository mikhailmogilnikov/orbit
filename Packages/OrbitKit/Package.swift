// swift-tools-version: 6.2
import PackageDescription

#if os(Linux)
/// Linux (CI, cloud sessions) builds only the language-server client, so its
/// integration tests run against real servers there too (D55).
let package = Package(
    name: "OrbitKit",
    dependencies: [
        // Same as the macOS build; the grammar tests parse with it.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
    ],
    targets: [
        .target(name: "OrbitACP"),
        .target(name: "OrbitAPI", sources: ["LanguageIntelligence.swift", "Completion.swift", "Grammars.swift", "LanguageEdits.swift"]),
        .target(
            name: "OrbitLanguages",
            dependencies: ["OrbitAPI", "OrbitACP"],
            sources: ["LanguageServer.swift", "LanguageServerConfig.swift", "TextChange.swift", "LanguageInstaller.swift"]
        ),
        .testTarget(
            name: "OrbitKitTests",
            dependencies: ["OrbitAPI", "OrbitACP", "OrbitLanguages", .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter")],
            exclude: ["Fixtures"],
            sources: ["LanguageServerTests.swift", "LanguageServerIntegrationTests.swift", "CompletionTests.swift", "LanguageInstallTests.swift", "GrammarTests.swift"]
        ),
    ]
)
#else
let package = Package(
    name: "OrbitKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OrbitKit", targets: ["OrbitKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/STTextView", from: "2.4.1"),
        .package(url: "https://github.com/krzyzanowskim/STTextView-Plugin-Neon", revision: "d568bf9"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", "1.20.0"..<"1.99.0"),
    ],
    targets: [
        .target(name: "OrbitACP"),
        .target(name: "OrbitAPI", resources: [.copy("Resources/Extensions")]),
        .target(name: "OrbitUI", dependencies: ["OrbitAPI"], resources: [.copy("Resources/OrbitMark.svg")]),
        .target(name: "OrbitExplorer", dependencies: ["OrbitAPI", "OrbitUI"]),
        .target(
            name: "OrbitEditor",
            dependencies: [
                "OrbitAPI", "OrbitUI",
                .product(name: "STTextView", package: "STTextView"),
                .product(name: "STTextView-Plugin-Neon", package: "STTextView-Plugin-Neon"),
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
        .target(name: "OrbitLanguages", dependencies: ["OrbitAPI", "OrbitUI", "OrbitACP"]),
        .target(
            name: "OrbitKit",
            dependencies: ["OrbitAPI", "OrbitUI", "OrbitExplorer", "OrbitEditor", "OrbitReview", "OrbitSearch", "OrbitGit", "OrbitTerminal", "OrbitAgents", "OrbitLanguages"]
        ),
        .testTarget(
            name: "OrbitKitTests",
            dependencies: ["OrbitAPI", "OrbitACP", "OrbitReview", "OrbitSearch", "OrbitTerminal", "OrbitGit", "OrbitAgents", "OrbitUI", "OrbitEditor", "OrbitLanguages",
                           .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter")],
            exclude: ["Fixtures"]
        ),
    ]
)
#endif
