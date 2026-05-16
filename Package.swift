// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TranscrybeDIY",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TranscrybeDIY",
            path: "Sources/TranscrybeDIY",
            swiftSettings: [
                // Swift 5 mode keeps the data-flow code (AsyncStream pumping
                // a non-Sendable AVAudioPCMBuffer into SFSpeech) tractable
                // without scattering @unchecked Sendable everywhere.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
