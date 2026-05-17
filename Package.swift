// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LiveTranslate",
    platforms: [.macOS(.v15)],
    targets: [
        // RNNoise (xiph, BSD 3-clause), pinned to v0.1.1 where the model
        // weights are embedded in the C sources (no runtime download).
        // See Sources/CRNNoise/LICENSE.
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                // The vendored C uses some warnings-prone older idioms;
                // silence them so our `-Werror`-curious eyes don't bleed
                // when we build.
                .unsafeFlags(["-Wno-implicit-function-declaration"]),
            ]
        ),
        .executableTarget(
            name: "LiveTranslate",
            dependencies: ["CRNNoise"],
            path: "Sources/LiveTranslate",
            swiftSettings: [
                // Swift 5 mode keeps the data-flow code (AsyncStream pumping
                // a non-Sendable AVAudioPCMBuffer into SFSpeech) tractable
                // without scattering @unchecked Sendable everywhere.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
