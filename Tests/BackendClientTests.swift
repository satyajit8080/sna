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
