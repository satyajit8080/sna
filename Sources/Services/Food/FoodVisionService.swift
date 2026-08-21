import Foundation
import UIKit

/// Food photo analysis.
///
/// A vision model names what is on the plate and estimates portions; nutrition
/// figures come from USDA. Every number that reaches the user is an estimate,
/// and the UI must present it as one — a photograph cannot tell you how much
/// salt went into a dish.
struct FoodVisionService: Sendable {

    struct DetectedFood: Identifiable, Equatable, Decodable {
        var id: String { name }
        let name: String
        let estimatedGrams: Int
        let confidence: Confidence
        let note: String?
        let sodiumMilligrams: Int?
        let calories: Int?
        let nutritionSource: String

        enum Confidence: String, Decodable, Equatable {
            case high, medium, low

            var label: String {
                switch self {
                case .high: "Clear"
                case .medium: "Probable"
                case .low: "Uncertain"
                }
            }

            /// Low-confidence identifications need a human eye before the
            /// numbers derived from them are trusted.
            var needsReview: Bool { self != .high }
        }

        var hasNutrition: Bool { sodiumMilligrams != nil }
    }

    enum VisionError: LocalizedError {
        case notConfigured
        case tooLarge
        case noFoodFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Food photo analysis is not set up in this build."
            case .tooLarge:
                "That photo is too large. Try again with a smaller image."
            case .noFoodFound:
                "No food was recognised in that photo. Try a clearer, closer shot."
            case .failed(let reason):
                reason
            }
        }
    }

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func analyse(_ image: UIImage) async throws -> [DetectedFood] {
        // Resized before upload. A full-resolution photo is several megabytes
        // of base64 for no benefit — the model reads a 1024px image just as
        // well, and the round trip is far quicker on a phone connection.
        guard let data = Self.prepare(image) else {
            throw VisionError.failed("That image could not be prepared.")
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/vision/food"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode([
            "imageBase64": data.base64EncodedString(),
            "mediaType": "image/jpeg",
        ])

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            // Distinguish a dropped upload from a refusal: the first is worth
            // retrying, the second is not.
            let code = (error as NSError).code
            if code == NSURLErrorNetworkConnectionLost || code == NSURLErrorTimedOut {
                throw VisionError.failed("""
                The upload did not complete. Try again — a stronger connection or a \
                smaller photo usually helps.
                """)
            }
            throw VisionError.failed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw VisionError.failed("Could not reach the server.")
        }

        switch http.statusCode {
        case 200:
            struct Envelope: Decodable {
                let items: [DetectedFood]
                let note: String?
            }
            let decoded = try JSONDecoder().decode(Envelope.self, from: responseData)
            guard !decoded.items.isEmpty else { throw VisionError.noFoodFound }
            return decoded.items
        case 413:
            throw VisionError.tooLarge
        case 503:
            throw VisionError.notConfigured
        default:
            throw VisionError.failed("The photo could not be analysed. Please try again.")
        }
    }

    /// Downscales and compresses for upload.
    ///
    /// 768px rather than 1024: a vision model identifies food just as well at
    /// that size, and the smaller payload matters more — a large upload on a
    /// phone connection was timing out and surfacing as a lost connection.
    static func prepare(_ image: UIImage, maxDimension: CGFloat = 768) -> Data? {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.6)
    }
}
