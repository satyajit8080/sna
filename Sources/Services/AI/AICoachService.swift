import Foundation

/// What the coach was asked to do. Kept explicit so each capability can carry
/// its own guardrails rather than relying on one catch-all prompt.
enum CoachRequest: Sendable {
    case explainReading(BPContextSnapshot.Reading)
    case whatMovedMyBP
    case weeklyReview
    case questionsForDoctor
    case freeform(String)
}

/// Text extracted from an attachment, on the device, ready to send.
struct CoachAttachmentPayload: Sendable, Equatable {
    let kind: String
    let name: String
    let text: String
}

struct CoachResponse: Sendable {
    let text: String
    /// What the answer was actually based on, so the user can check it.
    let basedOn: [String]
    /// True when the context was too thin to answer well.
    let hadInsufficientData: Bool
}

enum CoachError: LocalizedError {
    case notConfigured
    case offline
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "The AI coach is not set up yet."
        case .offline:
            "The coach needs a connection. Your readings are still saved."
        case .refused(let reason):
            reason
        }
    }
}

/// The boundary between BP Coach and any language model.
///
/// Nothing in the app talks to a provider directly. Swapping or adding one is a
/// new conformance to this protocol, and no provider is wired up yet — the app
/// reports that honestly rather than showing invented coaching text.
protocol AICoachService: Sendable {
    var isConfigured: Bool { get }
    func respond(
        to request: CoachRequest,
        context: BPContextSnapshot,
        attachments: [CoachAttachmentPayload]
    ) async throws -> CoachResponse
}

extension AICoachService {
    func respond(to request: CoachRequest, context: BPContextSnapshot) async throws -> CoachResponse {
        try await respond(to: request, context: context, attachments: [])
    }
}

/// Active until a provider is selected and approved.
///
/// It throws rather than returning plausible-sounding filler. Fake AI output in a
/// health app is worse than no output.
struct UnconfiguredCoachService: AICoachService {
    let isConfigured = false

    func respond(
        to request: CoachRequest,
        context: BPContextSnapshot,
        attachments: [CoachAttachmentPayload]
    ) async throws -> CoachResponse {
        throw CoachError.notConfigured
    }
}

/// Hard limits enforced in code, not only in a system prompt.
///
/// A model instructed not to do something will occasionally do it anyway, so the
/// rules that matter most are also structural: the safety engine is deterministic
/// and the coach is never consulted about urgency.
enum CoachGuardrails {
    static let prohibited = [
        "diagnosing a condition",
        "predicting future blood pressure",
        "recommending starting, stopping or changing a medication",
        "deciding whether a situation is an emergency",
    ]

    static let systemPreamble = """
    You are a blood pressure coach inside a personal health app. You explain the \
    user's own recorded data in plain language.

    You must never: diagnose a condition, predict future readings, recommend \
    starting or stopping or changing any medication, or judge whether something \
    is an emergency. Urgency is decided elsewhere by fixed clinical rules and is \
    not your responsibility.

    If the data you are given is missing or thin, say so plainly. Never invent a \
    reading, a number, or a trend that is not present in the context provided.
    """
}
