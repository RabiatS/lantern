import Foundation

/// Where a reply comes from. The downloaded MLX model is the point of the app;
/// Apple's built-in model is the comparison, the zero-download start, and a
/// helper for jobs it does well.
nonisolated enum BackendKind: String, Codable, CaseIterable, Sendable {
    case lantern
    case apple

    var title: String {
        switch self {
        case .lantern: "Lantern model"
        case .apple: "Apple Intelligence"
        }
    }

    var summary: String {
        switch self {
        case .lantern: "A model you download once and can read the numbers of. Any supported iPhone."
        case .apple: "Apple's built-in model, about 3 billion parameters, no download. iPhone 15 Pro or later with Apple Intelligence on."
        }
    }
}

/// The least an engine needs to offer for the benchmark to run on it.
nonisolated protocol GenerationBackend: Sendable {
    func generateOnce(_ prompt: String, maxTokens: Int) async -> AsyncThrowingStream<GenerationEvent, Error>
}

extension InferenceEngine: GenerationBackend {}
