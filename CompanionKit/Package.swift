// swift-tools-version: 6.0
import PackageDescription

// CompanionKit - the app's code as a local Swift package, the single source of truth for
// dependencies (think go.mod / go.sum via the committed Package.resolved). The Xcode app
// target (../project.yml) is a thin @main shell that depends on this package and handles only
// the menu-bar .app bundling/signing SwiftPM can't do.
//
// Module split (foundation spec):
//   • CompanionCore  - pure, DEPENDENCY-FREE. Rule model + evaluator, audit append, the hook
//                      payload/decision types. Shared by the app AND the latency-sensitive
//                      companion-hook. No GRDB here → the hook binary stays tiny / fast to cold-start.
//   • CompanionKit   - app library: SQLite (GRDB), usage client, JSONL tailer, cost, view models.
//   • companion-hook - the executable Claude Code invokes per tool call (depends on CompanionCore only).
let package = Package(
    name: "CompanionKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompanionKit", targets: ["CompanionKit"]),
        .executable(name: "companion-hook", targets: ["companion-hook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(name: "CompanionCore"),
        .target(
            name: "CompanionKit",
            dependencies: [
                "CompanionCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [
                .copy("Resources/default-rules.yaml"),
                .copy("Resources/default-pricing.yaml"),
            ]
        ),
        .executableTarget(
            name: "companion-hook",
            dependencies: ["CompanionCore"]
        ),
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionCore", "CompanionKit"]
        ),
    ],
    // Swift 6 language mode: complete strict-concurrency checking on our own code.
    // See swift6-language-mode.spec.md.
    swiftLanguageModes: [.v6]
)
