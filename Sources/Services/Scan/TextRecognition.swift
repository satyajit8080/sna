import Foundation
import UIKit
import Vision

/// On-device text recognition.
///
/// Apple's Vision framework runs entirely on the device, so a photographed
/// prescription or lab report never leaves it. That is the whole reason OCR is
/// not delegated to the backend.
enum TextRecognition {

    struct Result {
        let lines: [String]
        /// Vision's own per-observation confidence, averaged. Used to decide
        /// whether extracted values need review rather than being trusted.
        let averageConfidence: Float

        var text: String { lines.joined(separator: "\n") }
        var isEmpty: Bool { lines.isEmpty }
    }

    enum RecognitionError: LocalizedError {
        case invalidImage
        case noTextFound

        var errorDescription: String? {
            switch self {
            case .invalidImage: "That image could not be read."
            case .noTextFound:
                "No text was found. Try again with more light, and hold the camera steady and square to the page."
            }
        }
    }

    static func recognise(in image: UIImage) async throws -> Result {
        guard let cgImage = image.cgImage else { throw RecognitionError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let candidates = observations.compactMap { $0.topCandidates(1).first }

                guard !candidates.isEmpty else {
                    continuation.resume(throwing: RecognitionError.noTextFound)
                    return
                }

                let confidence = candidates.reduce(Float(0)) { $0 + $1.confidence }
                    / Float(candidates.count)

                continuation.resume(returning: Result(
                    lines: candidates.map(\.string),
                    averageConfidence: confidence
                ))
            }

            // Accurate is slower but materially better on printed lab reports,
            // which is the main thing being scanned here.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
