import Foundation

/// Backend endpoint configuration.
///
/// The base URL is the only thing the app needs to know. There is deliberately
/// no API key here: keys live on the server, because anything shipped in an
/// .ipa can be extracted from it.
enum BackendConfig {
    /// Set at build time via the `BPCOACH_API_BASE_URL` Info.plist value, which
    /// `project.yml` populates from an xcconfig or CI variable.
    static var baseURL: URL? {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "BPCoachAPIBaseURL") as? String,
            !raw.isEmpty,
            let url = URL(string: raw)
        else { return nil }
        return url
    }

    static var isConfigured: Bool { baseURL != nil }
}

/// Wire format for `POST /v1/coach`. Mirrors the server's `CoachRequestBody`.
private struct CoachRequestPayload: Encodable {
    struct Reading: Encodable {
        let systolic: Int
        let diastolic: Int
        let pulse: Int?
        let recordedAt: String
        let timeOfDay: String
        let source: String
        let category: String
        let notes: String?
    }

    struct Average: Encodable {
        let days: Int
        let systolic: Int
        let diastolic: Int
        let count: Int
    }

    struct MedicationSummary: Encodable {
        let name: String
        let dose: String
        let frequency: String
        let adherencePercent: Double?
    }

    struct LifestyleSummary: Encodable {
        let kind: String
        let total: Double
        let unit: String
        let isEstimate: Bool
    }

    let question: String
    let guidelineName: String
    let readings: [Reading]
    let averages: [Average]
    let variabilitySD: Double?
    let medications: [MedicationSummary]
    let lifestyle: [LifestyleSummary]
    let stepsToday: Int?
    let restingHeartRate: Int?
}

private struct CoachResponsePayload: Decodable {
    let text: String
    let readingsUsed: Int
    let guideline: String
}

private struct ErrorPayload: Decodable {
    let error: String
    let retryable: Bool?
    let configured: Bool?
}

/// Talks to the BP Coach backend, which holds the provider key and proxies the
/// request.
///
/// What crosses the network is the `BPContextSnapshot` and nothing else: no
/// profile identifier, no name, no raw HealthKit samples, no device
/// identifier. The server is stateless and stores none of it.
struct BackendCoachService: AICoachService {

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    var isConfigured: Bool { true }

    func respond(to request: CoachRequest, context: BPContextSnapshot) async throws -> CoachResponse {
        // Safety never routes through here. `SafetyEngine` decides urgency
        // on-device, deterministically, and the coach is not consulted.
        let question = Self.question(for: request)
        let payload = Self.payload(question: question, context: context)

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/coach"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 45
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw CoachError.offline
        }

        guard let http = response as? HTTPURLResponse else {
            throw CoachError.refused("Unexpected response from the coach service.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(ErrorPayload.self, from: data)
            if decoded?.configured == false || http.statusCode == 503 {
                throw CoachError.notConfigured
            }
            throw CoachError.refused(decoded?.error ?? "The coach could not answer that.")
        }

        let decoded = try JSONDecoder().decode(CoachResponsePayload.self, from: data)
        return CoachResponse(
            text: decoded.text,
            basedOn: ["\(decoded.readingsUsed) readings", decoded.guideline],
            hadInsufficientData: context.isTooSparse
        )
    }

    // MARK: - Mapping

    private static func question(for request: CoachRequest) -> String {
        switch request {
        case .freeform(let text):
            text
        case .whatMovedMyBP:
            "What moved my blood pressure recently?"
        case .weeklyReview:
            "Give me a short review of my week."
        case .questionsForDoctor:
            "What should I ask my doctor at my next appointment?"
        case .explainReading(let reading):
            "Explain my reading of \(reading.systolic)/\(reading.diastolic)."
        }
    }

    private static func payload(
        question: String,
        context: BPContextSnapshot
    ) -> CoachRequestPayload {
        let formatter = ISO8601DateFormatter()

        return CoachRequestPayload(
            question: question,
            guidelineName: context.guidelineName,
            readings: context.recentReadings.map {
                .init(
                    systolic: $0.systolic,
                    diastolic: $0.diastolic,
                    pulse: $0.pulse,
                    recordedAt: formatter.string(from: $0.recordedAt),
                    timeOfDay: $0.timeOfDay,
                    source: $0.source,
                    category: $0.category,
                    notes: $0.notes
                )
            },
            averages: context.averages.map {
                .init(days: $0.days, systolic: $0.systolic, diastolic: $0.diastolic, count: $0.count)
            },
            variabilitySD: context.variabilitySD,
            medications: context.medications.map {
                .init(
                    name: $0.name,
                    dose: $0.dose,
                    frequency: $0.frequency,
                    adherencePercent: $0.adherencePercent
                )
            },
            lifestyle: context.lifestyle.map {
                .init(kind: $0.kind, total: $0.total, unit: $0.unit, isEstimate: $0.isEstimate)
            },
            stepsToday: context.stepsToday,
            restingHeartRate: context.restingHeartRate
        )
    }
}
