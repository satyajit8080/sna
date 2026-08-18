import Foundation

/// Pulls named values out of recognised text.
///
/// Deliberately rule-based rather than AI. A lab value is a number next to a
/// label with a unit — that is a parsing job, and a parser can be tested and
/// will not invent a result. Anything it cannot read confidently is marked for
/// review rather than guessed at.
enum ValueExtraction {

    /// Analytes worth recognising in a blood-pressure context, with the units
    /// commonly printed beside them.
    private static let known: [(name: String, patterns: [String], units: [String])] = [
        ("Total cholesterol", ["total cholesterol", "cholesterol, total", "t chol"], ["mg/dl", "mmol/l"]),
        ("LDL cholesterol", ["ldl", "ldl-c", "ldl cholesterol"], ["mg/dl", "mmol/l"]),
        ("HDL cholesterol", ["hdl", "hdl-c", "hdl cholesterol"], ["mg/dl", "mmol/l"]),
        ("Triglycerides", ["triglyceride", "tg"], ["mg/dl", "mmol/l"]),
        ("Creatinine", ["creatinine", "s. creatinine"], ["mg/dl", "umol/l", "µmol/l"]),
        ("eGFR", ["egfr", "gfr"], ["ml/min"]),
        ("Sodium", ["sodium", "na+", "serum sodium"], ["mmol/l", "meq/l"]),
        ("Potassium", ["potassium", "k+"], ["mmol/l", "meq/l"]),
        ("HbA1c", ["hba1c", "glycated", "a1c"], ["%", "mmol/mol"]),
        ("Fasting glucose", ["fasting glucose", "fbs", "glucose fasting"], ["mg/dl", "mmol/l"]),
        ("Haemoglobin", ["haemoglobin", "hemoglobin", "hb"], ["g/dl"]),
        ("TSH", ["tsh", "thyroid stimulating"], ["miu/l", "uiu/ml"]),
    ]

    /// A number, optionally decimal, not part of a longer token.
    private static let numberPattern = #"(?<![\w.])(\d{1,4}(?:\.\d{1,2})?)(?![\w])"#

    /// A printed reference range: "70 - 100", "70–100", "< 140".
    private static let rangePattern = #"(\d{1,4}(?:\.\d{1,2})?)\s*[-–—]\s*(\d{1,4}(?:\.\d{1,2})?)"#

    struct Candidate {
        let name: String
        let value: String
        let unit: String?
        let referenceRange: String?
        let isWithinRange: Bool?
        let sourceLine: String
        let confidence: ExtractionConfidence
    }

    static func extract(from lines: [String], ocrConfidence: Float) -> [Candidate] {
        var found: [Candidate] = []

        for line in lines {
            let lower = line.lowercased()

            guard let match = known.first(where: { entry in
                entry.patterns.contains { lower.contains($0) }
            }) else { continue }

            guard let value = firstNumber(in: line) else { continue }

            let unit = match.units.first { lower.contains($0) }
            let range = referenceRange(in: line)

            // Only judge in-range when both a value and a printed range are
            // present. Absent means unknown — never "normal".
            var withinRange: Bool?
            if let range, let numeric = Double(value) {
                withinRange = range.low <= numeric && numeric <= range.high
            }

            found.append(Candidate(
                name: match.name,
                value: value,
                unit: unit,
                referenceRange: range.map { "\(formatted($0.low)) – \(formatted($0.high))" },
                isWithinRange: withinRange,
                sourceLine: line.trimmingCharacters(in: .whitespaces),
                confidence: confidence(ocr: ocrConfidence, hasUnit: unit != nil, hasRange: range != nil)
            ))
        }

        // The same analyte can appear on several lines (header, then value).
        // Keep the first, which is where the value normally sits.
        var seen = Set<String>()
        return found.filter { seen.insert($0.name).inserted }
    }

    private static func confidence(
        ocr: Float, hasUnit: Bool, hasRange: Bool
    ) -> ExtractionConfidence {
        // A value read cleanly, with its unit and range beside it, is about as
        // certain as OCR gets. Anything less is flagged for a human check.
        if ocr > 0.85 && hasUnit && hasRange { return .high }
        if ocr > 0.6 && hasUnit { return .medium }
        return .low
    }

    private static func firstNumber(in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: numberPattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let matched = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[matched])
    }

    private static func referenceRange(in line: String) -> (low: Double, high: Double)? {
        guard let regex = try? NSRegularExpression(pattern: rangePattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let lowRange = Range(match.range(at: 1), in: line),
              let highRange = Range(match.range(at: 2), in: line),
              let low = Double(line[lowRange]),
              let high = Double(line[highRange]),
              low < high
        else { return nil }
        return (low, high)
    }

    private static func formatted(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

/// Pulls medicine names and dosages out of a prescription.
///
/// Output is always presented as a *suggestion* requiring confirmation. Nothing
/// here is treated as an identification — a misread strength on a prescription
/// is exactly the error that must never be saved silently.
enum PrescriptionExtraction {

    struct Suggestion: Identifiable {
        let id = UUID()
        var name: String
        var dose: String?
        var frequency: MedicationFrequency?
        let sourceLine: String
        let confidence: ExtractionConfidence
    }

    private static let dosePattern = #"(\d{1,4}(?:\.\d{1,2})?)\s*(mg|mcg|g|ml|iu)\b"#

    private static let frequencyHints: [(MedicationFrequency, [String])] = [
        (.onceDaily, ["once daily", "od", "1-0-0", "qd", "every morning", "daily"]),
        (.twiceDaily, ["twice daily", "bd", "bid", "1-0-1", "morning and night"]),
        (.threeTimesDaily, ["three times", "tds", "tid", "1-1-1"]),
        (.asNeeded, ["as needed", "prn", "when required"]),
    ]

    static func suggestions(from lines: [String], ocrConfidence: Float) -> [Suggestion] {
        var results: [Suggestion] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { continue }

            guard let dose = firstDose(in: trimmed) else { continue }

            // The medicine name is normally whatever precedes the strength.
            let name = trimmed
                .replacingOccurrences(of: dose, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:•*.,()"))

            guard name.count >= 3, name.rangeOfCharacter(from: .letters) != nil else { continue }

            let lower = trimmed.lowercased()
            let frequency = frequencyHints.first { _, hints in
                hints.contains { lower.contains($0) }
            }?.0

            results.append(Suggestion(
                name: name,
                dose: dose,
                frequency: frequency,
                sourceLine: trimmed,
                // Never high. A prescription read by OCR always warrants review.
                confidence: ocrConfidence > 0.8 ? .medium : .low
            ))
        }
        return results
    }

    private static func firstDose(in line: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: dosePattern, options: .caseInsensitive
        ) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let matched = Range(match.range, in: line) else { return nil }
        return String(line[matched])
    }
}
