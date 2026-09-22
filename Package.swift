// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ResponseAi",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ResponseAi", targets: ["ResponseAi"]),
        .library(name: "ResAICore", targets: ["ResAICore"])
    ],
    targets: [
        .target(
            name: "ResAICore",
            path: "Sources/ResAICore"
        ),
        .executableTarget(
            name: "ResponseAi",
            dependencies: ["ResAICore"],
            path: "Sources/ResAI"
        ),
        .testTarget(
            name: "ResAICoreTests",
            dependencies: ["ResAICore"],
            path: "Tests/ResAICoreTests"
        ),
        .testTarget(
            name: "ResponseAiTests",
            dependencies: ["ResponseAi"],
            path: "Tests/ResponseAiTests"
        )
    ]
)
