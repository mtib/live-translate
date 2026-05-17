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
                // The vendored C uses some warnings-prone older idioms.
                .unsafeFlags([
                    "-Wno-implicit-function-declaration",
                    // rnn.c has intentional null-dereference patterns (upstream
                    // xiph code uses NULL deref as a compile-time assert trick).
                    "-Wno-null-dereference",
                ]),
            ]
        ),
        // Thin bridge target around the externally-built whisper.cpp
        // static libraries. The libraries themselves live under
        // build/whisper-prefix/ and are produced by tools/build-whisper.sh
        // before `swift build`. SwiftPM doesn't ship a way to declare an
        // external CMake dependency, so we use header search + linker
        // unsafe-flags pointing at the locally-built prefix.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                // whisper.h is copied in by tools/build-whisper.sh — it
                // lives next to the bridge header at module-build time.
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L./build/whisper-prefix/lib",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-blas",
                    "-lggml-metal",
                    // whisper.cpp + ggml are C++ — pull in libc++ for
                    // the C++ runtime symbols (__cxa_throw,
                    // __gxx_personality_v0, etc.).
                    "-lc++",
                ]),
                // Metal + MetalKit are needed because the ggml-metal
                // backend is statically linked in and references Apple's
                // Metal API surface.
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "LiveTranslate",
            dependencies: ["CRNNoise", "CWhisper"],
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
