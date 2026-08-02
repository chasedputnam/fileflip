// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FileConvert",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FileConvertCore", targets: ["FileConvertCore"]),
        .library(name: "FileConvertProviders", targets: ["FileConvertProviders"]),
        .library(name: "FileConvertEvidence", targets: ["FileConvertEvidence"]),
        .executable(name: "FileConvertApp", targets: ["FileConvertApp"]),
        .executable(name: "packaged-media-matrix", targets: ["packaged-media-matrix"]),
        .executable(name: "packaged-media-smoke", targets: ["packaged-media-smoke"]),
        .executable(name: "packaged-media-contract", targets: ["packaged-media-contract"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(name: "FileConvertCore"),
        .target(
            name: "FileConvertProviders",
            dependencies: ["FileConvertCore"]
        ),
        .target(
            name: "FileConvertEvidence",
            dependencies: ["FileConvertCore", "FileConvertProviders"]
        ),
        .executableTarget(
            name: "packaged-media-matrix",
            dependencies: ["FileConvertCore", "FileConvertProviders", "FileConvertEvidence"]
        ),
        .executableTarget(
            name: "packaged-media-smoke",
            dependencies: ["FileConvertCore", "FileConvertProviders", "FileConvertEvidence"]
        ),
        .executableTarget(
            name: "packaged-media-contract",
            dependencies: ["FileConvertProviders", "FileConvertEvidence"]
        ),
        .executableTarget(
            name: "FileConvertApp",
            dependencies: [
                "FileConvertCore",
                "FileConvertProviders",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .copy("Resources/MediaTools"),
            ]
        ),
        .testTarget(name: "FileConvertCoreTests", dependencies: ["FileConvertCore"]),
        .testTarget(
            name: "FileConvertProvidersTests",
            dependencies: ["FileConvertProviders"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "FileConvertEvidenceTests", dependencies: ["FileConvertEvidence", "FileConvertCore", "FileConvertProviders"]),
        .testTarget(name: "FileConvertIntegrationTests", dependencies: ["FileConvertCore", "FileConvertProviders", "FileConvertEvidence"]),
        .testTarget(name: "FileConvertAppTests", dependencies: ["FileConvertApp", "FileConvertCore"]),
    ],
    swiftLanguageModes: [.v6]
)
