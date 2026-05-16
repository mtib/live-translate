// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LiveTranslate",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LiveTranslate",
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
