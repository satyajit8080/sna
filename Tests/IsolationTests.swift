import Foundation
import SwiftData
import Testing

@testable import BPCoach

/// Profile isolation and AI context bounds. These are privacy invariants — if one
/// of these fails, one person's health data has leaked into another's view.
@Suite("Profile and context isolation")
@MainActor
struct IsolationTests {

    private func makeContainer() throws -> ModelContainer {
        try PersistenceController.makeContainer(inMemory: true)
    }

    @Test("HealthKit is owner-only by profile kind")
    func healthKitOwnership() {
        #expect(ProfileKind.owner.canUseHealthKit)
        #expect(!ProfileKind.spouse.canUseHealthKit)
        #expect(!ProfileKind.parent.canUseHealthKit)
        #expect(!ProfileKind.other.canUseHealthKit)
    }

    @Test("Requesting HealthKit for a non-owner profile throws")
    func nonOwnerRefused() async {
        let service = HealthKitService(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spouse = UserProfile(name: "Spouse", kind: .spouse)

        await #expect(throws: (any Error).self) {
            try await service.requestAuthorization(for: spouse)
        }
    }

    @Test("AI context includes only the active profile's readings")
    func contextIsProfileScoped() throws {
        let ownerID = UUID()
        let otherID = UUID()

        let readings = [
            BPReading(profileID: ownerID, systolic: 120, diastolic: 80),
            BPReading(profileID: ownerID, systolic: 130, diastolic: 85),
            BPReading(profileID: otherID, systolic: 190, diastolic: 120),
        ]

        let engine = AIContextEngine(guideline: ACCAHA2017Guideline())
        let snapshot = engine.makeSnapshot(
            profileID: ownerID,
            readings: readings,
            medications: [],
            doses: [],
            lifestyle: []
        )

        #expect(snapshot.recentReadings.count == 2)
        #expect(!snapshot.recentReadings.contains { $0.systolic == 190 })
    }

    @Test("AI context is capped and never dumps the database")
    func contextIsCapped() throws {
        let profileID = UUID()
        let readings = (0..<200).map { index in
            BPReading(
                profileID: profileID,
                systolic: 120 + (index % 20),
                diastolic: 80,
                recordedAt: Date.now.addingTimeInterval(-Double(index) * 3_600)
            )
        }

        let engine = AIContextEngine(guideline: ACCAHA2017Guideline())
        let snapshot = engine.makeSnapshot(
            profileID: profileID,
            readings: readings,
            medications: [],
            doses: [],
            lifestyle: []
        )

        #expect(snapshot.recentReadings.count == AIContextEngine.readingLimit)
        #expect(snapshot.recentReadings.count < readings.count)
    }

    @Test("Sparse data is reported as sparse, not padded")
    func sparseIsHonest() {
        let engine = AIContextEngine(guideline: ACCAHA2017Guideline())
        let snapshot = engine.makeSnapshot(
            profileID: UUID(),
            readings: [],
            medications: [],
            doses: [],
            lifestyle: []
        )
        #expect(snapshot.isTooSparse)
        #expect(snapshot.recentReadings.isEmpty)
        #expect(snapshot.averages.isEmpty)
    }

    @Test("Unconfigured coach refuses rather than inventing an answer")
    func coachRefuses() async {
        let coach = UnconfiguredCoachService()
        let snapshot = BPContextSnapshot(generatedAt: .now, guidelineName: "ACC/AHA 2017")
        #expect(!coach.isConfigured)

        await #expect(throws: CoachError.self) {
            _ = try await coach.respond(to: .whatMovedMyBP, context: snapshot)
        }
    }

    @Test("Unconfigured food provider returns nothing rather than fake sodium")
    func foodProviderIsHonest() async throws {
        let provider = UnconfiguredFoodDataProvider()
        #expect(!provider.isAvailable)
        #expect(try await provider.search("soup", limit: 10).isEmpty)
        #expect(try await provider.item(withID: "anything") == nil)
    }

    @Test("SwiftData container builds with the full schema")
    func containerBuilds() throws {
        let container = try makeContainer()
        let reading = BPReading(profileID: UUID(), systolic: 120, diastolic: 80)
        container.mainContext.insert(reading)
        try container.mainContext.save()

        let fetched = try container.mainContext.fetch(FetchDescriptor<BPReading>())
        #expect(fetched.count == 1)
    }
}
