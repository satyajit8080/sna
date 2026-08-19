import Foundation
import Testing

@testable import BPCoach

/// Tests for the network boundary.
///
/// The critical property is what does NOT cross it: no profile identifier, no
/// name, no raw HealthKit samples, no device identifier. These assertions are
/// the enforcement of that.
@Suite("Backend client")
@MainActor
struct BackendClientTests {

    private func snapshot(readings: Int = 5) -> BPContextSnapshot {
        var snapshot = BPContextSnapshot(generatedAt: .now, guidelineName: "ACC/AHA 2017")
        snapshot.recentReadings = (0..<readings).map { index in
            .init(
                systolic: 120 + index,
                diastolic: 80,
                pulse: 70,
                recordedAt: Date.now.addingTimeInterval(-Double(index) * 3_600),
                timeOfDay: "Morning",
                source: "Manual",
                category: "Normal",
                notes: nil
            )
        }
        snapshot.averages = [.init(days: 7, systolic: 122, diastolic: 80, count: readings)]
        return snapshot
    }

    @Test("Unconfigured base URL falls back to the honest stub, never a broken client")
    func fallsBackWhenUnconfigured() {
        // No Info.plist value is set in the test bundle.
        #expect(BackendConfig.baseURL == nil)
        #expect(!BackendConfig.isConfigured)
    }

    @Test("Backend service reports itself configured once a URL exists")
    func configuredWithURL() {
        let service = BackendCoachService(baseURL: URL(string: "https://example.invalid")!)
        #expect(service.isConfigured)
    }

    @Test("Food provider returns nothing for a too-short query without a network call")
    func shortQueryShortCircuits() async throws {
        let provider = BackendFoodProvider(baseURL: URL(string: "https://example.invalid")!)
        #expect(try await provider.search("a", limit: 10).isEmpty)
        #expect(try await provider.search("", limit: 10).isEmpty)
    }

    @Test("Portion maths scales from per-100g, never passing it through unchanged")
    func portionScaling() {
        let item = FoodItem(
            id: "1", name: "Soup", brand: nil,
            sodiumMilligramsPer100g: 400,
            energyKilocaloriesPer100g: 60,
            defaultServingGrams: 250,
            source: "USDA",
            provenance: .databaseLookup
        )
        #expect(FoodPortion.sodiumMilligrams(for: item, grams: 250) == 1000)
        #expect(FoodPortion.sodiumMilligrams(for: item, grams: 100) == 400)
        #expect(FoodPortion.calories(for: item, grams: 250) == 150)
        #expect(FoodPortion.defaultGrams(for: item) == 250)
    }

    @Test("Missing serving size falls back to 100 g rather than zero")
    func portionFallback() {
        let item = FoodItem(
            id: "2", name: "Bread", brand: nil,
            sodiumMilligramsPer100g: 500,
            energyKilocaloriesPer100g: nil,
            defaultServingGrams: nil,
            source: "USDA",
            provenance: .databaseLookup
        )
        #expect(FoodPortion.defaultGrams(for: item) == 100)
        #expect(FoodPortion.calories(for: item, grams: 100) == nil)
    }

    @Test("Database lookups are not tagged as estimates")
    func lookupProvenance() {
        let item = FoodItem(
            id: "3", name: "Rice", brand: nil,
            sodiumMilligramsPer100g: 1,
            energyKilocaloriesPer100g: 130,
            defaultServingGrams: 150,
            source: "USDA",
            provenance: .databaseLookup
        )
        #expect(!item.provenance.isEstimate)
    }

    /// The context that leaves the device is the whole privacy surface of the
    /// backend. If a profile ID or a name ever appears in it, that is a leak.
    @Test("Snapshot carries no identifiers to send")
    func snapshotHasNoIdentifiers() {
        let context = snapshot()
        let mirror = Mirror(reflecting: context)
        let fieldNames = mirror.children.compactMap(\.label).map { $0.lowercased() }

        #expect(!fieldNames.contains { $0.contains("profileid") })
        #expect(!fieldNames.contains { $0.contains("name") && !$0.contains("guideline") })
        #expect(!fieldNames.contains { $0.contains("deviceid") })
        #expect(!fieldNames.contains { $0.contains("email") })
    }

    @Test("Snapshot never exceeds the reading cap that the server also enforces")
    func snapshotRespectsCap() {
        let profileID = UUID()
        let readings = (0..<500).map { index in
            BPReading(
                profileID: profileID,
                systolic: 120,
                diastolic: 80,
                recordedAt: Date.now.addingTimeInterval(-Double(index) * 600)
            )
        }
        let engine = AIContextEngine(guideline: ACCAHA2017Guideline())
        let context = engine.makeSnapshot(
            profileID: profileID,
            readings: readings,
            medications: [],
            doses: [],
            lifestyle: []
        )
        #expect(context.recentReadings.count == AIContextEngine.readingLimit)
    }

    @Test("Coach errors map to user-facing states rather than raw failures")
    func errorMapping() {
        #expect(CoachError.notConfigured.errorDescription != nil)
        #expect(CoachError.offline.errorDescription != nil)
        #expect(CoachError.refused("nope").errorDescription == "nope")
    }
}

/// Coach attachments.
///
/// The privacy property that matters: attachments are reduced to text on the
/// device, so an image never crosses the network. These pin that.
@Suite("Coach attachments")
@MainActor
struct CoachAttachmentTests {

    @Test("An attachment carries text, not image data")
    func attachmentIsText() {
        let attachment = CoachAttachment(
            kind: .photo, name: "Label", text: "Sodium 480mg per serving"
        )
        #expect(!attachment.isEmpty)
        #expect(attachment.text.contains("480"))
    }

    @Test("Empty attachments are recognised as empty")
    func emptyDetected() {
        #expect(CoachAttachment(kind: .document, name: "x", text: "   ").isEmpty)
        #expect(CoachAttachment(kind: .document, name: "x", text: "").isEmpty)
    }

    @Test("Long text is truncated for preview but kept in full for sending")
    func previewTruncates() {
        let attachment = CoachAttachment(
            kind: .document, name: "Report", text: String(repeating: "a", count: 500)
        )
        #expect(attachment.preview.count < 200)
        #expect(attachment.text.count == 500)
    }

    /// A stored document contributes its extracted values, its reference ranges
    /// and its uncertainty — the last of these matters most.
    @Test("A saved report becomes readable attachment text")
    func documentBecomesText() {
        let document = MedicalDocument(profileID: UUID(), kind: .bloodTest, title: "Blood test")
        document.values = [
            ExtractedValue(
                name: "LDL cholesterol", value: "118", unit: "mg/dl",
                referenceRange: "70 – 130", isWithinRange: true, confidence: .high
            ),
            ExtractedValue(name: "Creatinine", value: "2.4", confidence: .low),
        ]

        let attachment = AttachmentReader.read(document: document)
        #expect(attachment.kind == .report)
        #expect(attachment.text.contains("LDL cholesterol"))
        #expect(attachment.text.contains("within range"))
        #expect(attachment.text.contains("read uncertainly"))
    }

    @Test("Suggested questions adapt to sparse data")
    func suggestionsForSparseData() {
        let sparse = BPContextSnapshot(generatedAt: .now, guidelineName: "ACC/AHA 2017")
        let items = SuggestedQuestion.forContext(sparse, hasDocuments: false)
        #expect(!items.isEmpty)
        #expect(items.contains { $0.text.lowercased().contains("taking my readings") })
    }

    @Test("Report questions only appear when reports exist")
    func suggestionsRespectDocuments() {
        var context = BPContextSnapshot(generatedAt: .now, guidelineName: "ACC/AHA 2017")
        context.recentReadings = (0..<5).map { _ in
            .init(systolic: 120, diastolic: 80, pulse: nil, recordedAt: .now,
                  timeOfDay: "Morning", source: "Manual", category: "Normal", notes: nil)
        }

        let without = SuggestedQuestion.forContext(context, hasDocuments: false)
        let with = SuggestedQuestion.forContext(context, hasDocuments: true)

        #expect(!without.contains { $0.text.contains("report") })
        #expect(with.contains { $0.text.contains("report") })
    }

    @Test("Attachment payloads carry only kind, name and text")
    func payloadShape() {
        let payload = CoachAttachmentPayload(kind: "photo", name: "Label", text: "content")
        let mirror = Mirror(reflecting: payload)
        let fields = Set(mirror.children.compactMap(\.label))
        #expect(fields == ["kind", "name", "text"])
    }
}

/// Backend URL validation.
///
/// The CI sentinel `unset` parses as a valid relative URL, so a naive
/// `URL(string:)` check made the app believe it was configured and report a
/// connection failure instead of "not set up". These pin the stricter rule.
@Suite("Backend URL validation")
struct BackendURLTests {

    /// Mirrors `BackendConfig.baseURL`'s rule so it can be exercised without a
    /// bundle. Kept identical deliberately.
    private func isValid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != "unset",
              !trimmed.hasPrefix("$("),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host(),
              host.contains(".")
        else { return false }
        return true
    }

    @Test("A real https URL is accepted")
    func acceptsRealURL() {
        #expect(isValid("https://bp-coach-production.up.railway.app"))
        #expect(isValid("https://api.example.com/v1"))
    }

    /// The bug this suite exists for.
    @Test("The CI sentinel is rejected, not treated as a host")
    func rejectsSentinel() {
        #expect(!isValid("unset"))
        #expect(!isValid("UNSET"))
    }

    @Test("An unexpanded build variable is rejected")
    func rejectsUnexpandedVariable() {
        #expect(!isValid("$(BPCOACH_API_BASE_URL)"))
    }

    @Test("Empty and whitespace are rejected")
    func rejectsEmpty() {
        #expect(!isValid(""))
        #expect(!isValid("   "))
    }

    @Test("A bare word or missing scheme is rejected")
    func rejectsBareWords() {
        #expect(!isValid("localhost"))
        #expect(!isValid("example.com"))
        #expect(!isValid("/v1/coach"))
    }

    @Test("A non-web scheme is rejected")
    func rejectsOtherSchemes() {
        #expect(!isValid("ftp://example.com"))
        #expect(!isValid("bpcoach://coach"))
    }
}
