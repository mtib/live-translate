import Foundation
import Translation

/// Wraps a `TranslationSession`. The session is only obtainable through
/// SwiftUI's `.translationTask` modifier, so the View pushes one into us
/// whenever the configuration (source/target language) changes. The
/// Pipeline asks `translate(_:)` and either gets a translated string back
/// or `TranslateError.noSession` if the session hasn't been set yet.
@MainActor
final class AppleTranslator: Translator {
    private var session: TranslationSession?

    func setSession(_ session: TranslationSession?) {
        self.session = session
        Log.line("AppleTranslator: session \(session == nil ? "cleared" : "set")")
    }

    func translate(_ text: String) async throws -> String {
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
