// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KEFCompanion",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KEFCompanion", targets: ["KEFCompanionExecutable"]),
        .library(name: "KEFCompanionDevPayload", type: .dynamic, targets: ["KEFCompanion"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
    ],
    targets: [
        .target(
            name: "KEFCompanion",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/KEFCompanion",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "KEFCompanionExecutable",
            dependencies: ["KEFCompanion"],
            path: "Sources/KEFCompanionExecutable"
        ),
        .testTarget(
            name: "KEFCompanionTests",
            dependencies: ["KEFCompanion"],
            path: "Tests/KEFCompanionTests",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        )
    ]
)
