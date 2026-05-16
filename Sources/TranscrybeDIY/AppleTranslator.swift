import Foundation
import Translation

/// Wraps a `TranslationSession`, which Apple's framework only hands out via
/// the SwiftUI `.translationTask` modifier. The View provides us with a
/// session whenever the configuration (source/target) changes; the Pipeline
/// calls translate() asynchronously and gets back a string.
///
/// If no session has been provided yet (e.g. translation disabled, or
/// language pair not configured), translate() throws `.noSession`.
@MainActor
final class AppleTranslator: Translator {
    private var session: TranslationSession?

    func setSession(_ session: TranslationSession?) {
        self.session = session
        Log.line("AppleTranslator: session \(session == nil ? "cleared" : "set")")
    }

    func translate(_ text: String, from: SourceLocale, to: TargetLanguage) async throws -> String {
        guard let session else { throw TranslateError.noSession }
        let response = try await session.translate(text)
        return response.targetText
    }
}

enum TranslateError: LocalizedError {
    case noSession
    var errorDescription: String? {
        switch self {
        case .noSession: return "Translation not ready — no session yet."
        }
    }
}
