# CRNNoise — vendored RNNoise

This directory is a verbatim copy of [xiph/rnnoise@v0.1.1](https://github.com/xiph/rnnoise/tree/v0.1.1)
(BSD 3-clause-style; see [LICENSE](LICENSE)). v0.1.1 was chosen because
the GRU model weights are statically linked from `rnn_data.c` (~400 KB),
so the library compiles into the app with zero runtime dependencies and
no model-file download.

Swift wrapper lives at `Sources/LiveTranslate/RNNoiseProcessor.swift`.

The C target is declared in `Package.swift`. Apple Silicon picks up
NEON automatically via the surrounding `__aarch64__` guards inside the
vendored sources; on Intel the scalar fallback is used.
