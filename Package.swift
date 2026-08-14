// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Ampestra",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "Ampestra", targets: ["AmpestraExecutable"]),
        .library(name: "AmpestraDevPayload", type: .dynamic, targets: ["Ampestra"]),
        .library(name: "KEFCore", targets: ["KEFCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
    ],
    targets: [
        .target(
            name: "KEFCore",
            path: "Sources/KEFCore"
        ),
        .target(
            name: "Ampestra",
            dependencies: [
                "KEFCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Ampestra",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "AmpestraExecutable",
            dependencies: ["Ampestra"],
            path: "Sources/AmpestraExecutable"
        ),
        .testTarget(
            name: "AmpestraTests",
            dependencies: ["Ampestra", "KEFCore"],
            path: "Tests/AmpestraTests",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        )
    ]
)
