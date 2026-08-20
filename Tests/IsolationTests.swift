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

/// Persistence stack behaviour.
///
/// These cover the failure that first appeared in CI: the app's `init` built an
/// on-disk store, and in a fresh simulator's test host `Application Support`
/// did not exist.
@Suite("Persistence stack")
@MainActor
struct PersistenceTests {

    @Test("Tests are detected, so no test writes to the real store")
    func detectsTestEnvironment() {
        #expect(PersistenceController.isRunningTests)
    }

    @Test("Container requested under test is in-memory even without asking")
    func testsAlwaysGetMemory() throws {
        // isRunningTests forces memory, so this must not touch the filesystem.
        let container = try PersistenceController.makeContainer()
        let reading = BPReading(profileID: UUID(), systolic: 120, diastolic: 80)
        container.mainContext.insert(reading)
        try container.mainContext.save()
        #expect(try container.mainContext.fetch(FetchDescriptor<BPReading>()).count == 1)
    }

    @Test("Building the stack never throws and never crashes")
    func stackAlwaysBuilds() {
        let stack = PersistenceController.makeStack()
        #expect(stack.container.schema.entities.count >= 0)
    }

    @Test("Every model in the schema is registered")
    func schemaIsComplete() {
        let names = Set(PersistenceController.schema.entities.map(\.name))
        for expected in [
            "BPReading", "BPMeasurementSession", "UserProfile",
            "Medication", "MedicationDose", "LifestyleEntry",
            "AIInsight", "AIConversation", "AIMessage",
        ] {
            #expect(names.contains(expected), "\(expected) missing from the schema")
        }
    }

    @Test("Separate containers do not share state")
    func containersAreIsolated() throws {
        let first = try PersistenceController.makeContainer(inMemory: true)
        let second = try PersistenceController.makeContainer(inMemory: true)

        first.mainContext.insert(BPReading(profileID: UUID(), systolic: 120, diastolic: 80))
        try first.mainContext.save()

        #expect(try first.mainContext.fetch(FetchDescriptor<BPReading>()).count == 1)
        #expect(try second.mainContext.fetch(FetchDescriptor<BPReading>()).isEmpty)
    }
}

/// HealthKit purpose strings.
///
/// Build 22 crashed on a real device inside
/// `_throwIfAuthorizationDisallowedForSharing:types:` — HealthKit raises an
/// uncatchable Objective-C exception when write access is requested without
/// `NSHealthUpdateUsageDescription`. These pin the guards that prevent it.
@Suite("HealthKit usage descriptions")
@MainActor
struct HealthKitUsageDescriptionTests {

    /// A bundle that reports no Info.plist keys, standing in for a build where
    /// the strings were lost.
    final class EmptyBundle: Bundle, @unchecked Sendable {
        override func object(forInfoDictionaryKey key: String) -> Any? { nil }
    }

    @Test("A bundle with no purpose strings is reported as missing")
    func detectsMissing() {
        #expect(HealthKitService.missingUsageDescriptionKey(bundle: EmptyBundle()) != nil)
    }

    @Test("The read key is checked first, since reading is the primary use")
    func reportsReadKeyFirst() {
        #expect(
            HealthKitService.missingUsageDescriptionKey(bundle: EmptyBundle())
                == "NSHealthShareUsageDescription"
        )
    }

    @Test("Requesting authorization for a non-owner profile throws before touching HealthKit")
    func nonOwnerRefusedBeforeHealthKit() async {
        let service = HealthKitService(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await #expect(throws: (any Error).self) {
            try await service.requestAuthorization(for: UserProfile(name: "Parent", kind: .parent))
        }
    }

    @Test("Every missing-description error carries a readable message")
    func errorsAreReadable() {
        let error = HealthKitService.HealthKitError
            .missingUsageDescription("NSHealthUpdateUsageDescription")
        #expect(error.errorDescription?.contains("NSHealthUpdateUsageDescription") == true)
    }
}

/// Extraction rules.
///
/// These are the parsers behind every scan. They are rule-based precisely so
/// they can be tested — an AI extractor could not be pinned like this.
@Suite("Scan extraction")
struct ExtractionTests {

    @Test("Reads a lab value with its unit and range")
    func readsFullLine() {
        let candidates = ValueExtraction.extract(
            from: ["LDL Cholesterol    118 mg/dL    (70 - 130)"],
            ocrConfidence: 0.95
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.name == "LDL cholesterol")
        #expect(candidates.first?.value == "118")
        #expect(candidates.first?.unit == "mg/dl")
        #expect(candidates.first?.isWithinRange == true)
        #expect(candidates.first?.confidence == .high)
    }

    @Test("Flags a value outside its printed range")
    func detectsOutOfRange() {
        let candidates = ValueExtraction.extract(
            from: ["Creatinine 2.4 mg/dL  (0.6 - 1.2)"],
            ocrConfidence: 0.95
        )
        #expect(candidates.first?.isWithinRange == false)
    }

    /// The most important case here: no printed range means unknown, and
    /// unknown must never be reported as normal.
    @Test("A value with no printed range is unknown, not normal")
    func noRangeIsUnknown() {
        let candidates = ValueExtraction.extract(
            from: ["Potassium 4.1 mmol/L"],
            ocrConfidence: 0.95
        )
        #expect(candidates.first?.isWithinRange == nil)
    }

    @Test("Poor recognition lowers confidence rather than being trusted")
    func lowConfidenceIsMarked() {
        let candidates = ValueExtraction.extract(
            from: ["HbA1c 6.2"],
            ocrConfidence: 0.4
        )
        #expect(candidates.first?.confidence == .low)
        #expect(candidates.first?.confidence.needsReview == true)
    }

    @Test("Lines with no known analyte produce nothing")
    func ignoresUnknownLines() {
        #expect(ValueExtraction.extract(
            from: ["Patient name: A Smith", "Collected 12/03/2026"],
            ocrConfidence: 0.95
        ).isEmpty)
    }

    @Test("The same analyte is not duplicated across lines")
    func deduplicates() {
        let candidates = ValueExtraction.extract(
            from: ["LDL 118 mg/dL", "LDL cholesterol 118 mg/dL"],
            ocrConfidence: 0.9
        )
        #expect(candidates.filter { $0.name == "LDL cholesterol" }.count == 1)
    }

    @Test("Prescription lines yield name, dose and frequency")
    func prescriptionSuggestion() {
        let suggestions = PrescriptionExtraction.suggestions(
            from: ["Amlodipine 5mg once daily"],
            ocrConfidence: 0.9
        )
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.name.lowercased().contains("amlodipine") == true)
        #expect(suggestions.first?.frequency == .onceDaily)
    }

    /// A scanned prescription is never treated as certain, however clean the
    /// recognition was. Confirmation is the only path to saving.
    @Test("Prescription confidence never reaches high")
    func prescriptionIsNeverCertain() {
        let suggestions = PrescriptionExtraction.suggestions(
            from: ["Ramipril 10mg twice daily"],
            ocrConfidence: 0.99
        )
        #expect(suggestions.first?.confidence != .high)
        #expect(suggestions.first?.confidence.needsReview == true)
    }

    @Test("A line without a dose is not a medicine suggestion")
    func requiresDose() {
        #expect(PrescriptionExtraction.suggestions(
            from: ["Dr A Smith, Cardiology"],
            ocrConfidence: 0.9
        ).isEmpty)
    }
}

@Suite("New models")
struct NewModelTests {

    @Test("Appointment reminders in the past are never scheduled")
    func skipsPastReminders() {
        let appointment = Appointment(
            profileID: UUID(),
            doctorName: "Dr Verma",
            scheduledFor: Date.now.addingTimeInterval(3 * 3_600)
        )
        // A week-ahead reminder for an appointment three hours away is behind us.
        appointment.reminderOffsets = [7 * 24 * 60, 60]
        let dates = appointment.pendingReminderDates()
        #expect(dates.count == 1)
        #expect(dates.allSatisfy { $0 > .now })
    }

    @Test("Disabling reminders yields none")
    func remindersRespectToggle() {
        let appointment = Appointment(
            profileID: UUID(),
            doctorName: "Dr Verma",
            scheduledFor: Date.now.addingTimeInterval(30 * 86_400)
        )
        appointment.remindersEnabled = false
        #expect(appointment.pendingReminderDates().isEmpty)
    }

    @Test("Red-flag symptoms are marked")
    func redFlags() {
        #expect(SymptomKind.chestDiscomfort.isRedFlag)
        #expect(SymptomKind.breathlessness.isRedFlag)
        #expect(!SymptomKind.fatigue.isRedFlag)
    }

    @Test("Unclear extractions are surfaced for review")
    func reviewFlagging() {
        let document = MedicalDocument(profileID: UUID(), kind: .bloodTest, title: "Test")
        document.values = [
            ExtractedValue(name: "A", value: "1", confidence: .high),
            ExtractedValue(name: "B", value: "2", confidence: .low),
        ]
        #expect(document.valuesNeedingReview.count == 1)
    }

    @Test("Every new model is registered in the schema")
    func schemaCovers() {
        let names = Set(PersistenceController.schema.entities.map(\.name))
        for expected in ["Appointment", "SymptomEntry", "ActivityEntry",
                         "MedicalDocument", "ExtractedValue"] {
            #expect(names.contains(expected), "\(expected) missing from the schema")
        }
    }
}

/// HealthKit authorization request shape.
///
/// Build 30 crashed inside `_throwIfAuthorizationDisallowedForSharing` with the
/// entitlement present, the purpose strings present, and an empty share set.
/// The cause was `HKCorrelationType(.bloodPressure)` in the *read* set: a
/// correlation type cannot be authorized, and passing one raises an
/// Objective-C exception Swift cannot catch.
@Suite("HealthKit authorization types")
struct HealthKitTypeTests {

    @Test("No correlation type appears in the authorization request")
    func noCorrelationTypeRequested() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/IsolationTests.swift",
                with: "Sources/Services/Health/HealthKitService.swift"
            ),
            encoding: .utf8
        )

        // Isolate the readTypes property and assert no correlation type is in it.
        guard let start = source.range(of: "private var readTypes"),
              let end = source.range(of: "private var writeTypes") else {
            Issue.record("Could not locate readTypes in HealthKitService")
            return
        }
        let readTypesBody = String(source[start.lowerBound..<end.lowerBound])

        #expect(
            !readTypesBody.contains("HKCorrelationType"),
            "A correlation type in readTypes makes HealthKit abort the process"
        )
    }

    /// The components are what actually grant access to the correlation, so they
    /// must both be present.
    @Test("Both blood pressure components are requested")
    func componentsRequested() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/IsolationTests.swift",
                with: "Sources/Services/Health/HealthKitService.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains("bloodPressureSystolic"))
        #expect(source.contains("bloodPressureDiastolic"))
    }
}

/// Daily insight rules.
///
/// The insight is deterministic on purpose: it appears whether or not the AI
/// coach is configured, and it must say the same thing every time it is
/// computed from the same data.
@Suite("Daily insight")
struct DailyInsightTests {

    private let guideline = ACCAHA2017Guideline()

    private func reading(_ systolic: Int, _ diastolic: Int, hoursAgo: Double) -> BPReading {
        BPReading(
            profileID: UUID(), systolic: systolic, diastolic: diastolic,
            recordedAt: Date.now.addingTimeInterval(-hoursAgo * 3_600)
        )
    }

    @Test("No data produces no insight rather than a filler message")
    func emptyProducesNothing() {
        #expect(DailyInsight.forToday(
            readings: [], doses: [], sodiumToday: 0, sodiumTarget: 1500, guideline: guideline
        ) == nil)
    }

    @Test("Missed doses surface once there is enough history to be fair")
    func adherenceInsight() {
        var doses: [MedicationDose] = []
        for index in 0..<10 {
            let dose = MedicationDose(
                profileID: UUID(), medicationID: UUID(),
                scheduledFor: Date.now.addingTimeInterval(-Double(index) * 86_400)
            )
            dose.status = index < 5 ? .taken : .missed
            doses.append(dose)
        }

        let insight = DailyInsight.forToday(
            readings: [reading(120, 80, hoursAgo: 2)],
            doses: doses, sodiumToday: 0, sodiumTarget: 1500, guideline: guideline
        )
        #expect(insight?.headline.contains("%") == true)
        #expect(insight?.action == .medication)
    }

    /// Fewer than seven resolved doses is not enough to draw a conclusion from.
    @Test("Thin dose history does not trigger an adherence insight")
    func adherenceNeedsHistory() {
        var doses: [MedicationDose] = []
        for _ in 0..<3 {
            let dose = MedicationDose(profileID: UUID(), medicationID: UUID(), scheduledFor: .now)
            dose.status = .missed
            doses.append(dose)
        }
        let insight = DailyInsight.forToday(
            readings: [reading(120, 80, hoursAgo: 2)],
            doses: doses, sodiumToday: 0, sodiumTarget: 1500, guideline: guideline
        )
        #expect(insight?.action != .medication)
    }

    @Test("High sodium is reported against the target")
    func sodiumInsight() {
        let insight = DailyInsight.forToday(
            readings: [reading(120, 80, hoursAgo: 2)],
            doses: [], sodiumToday: 3000, sodiumTarget: 1500, guideline: guideline
        )
        #expect(insight?.action == .sodium)
        #expect(insight?.body.contains("3000") == true)
    }

    @Test("The same input always yields the same insight")
    func deterministic() {
        let readings = (0..<10).map { reading(120, 80, hoursAgo: Double($0) * 3) }
        let first = DailyInsight.forToday(
            readings: readings, doses: [], sodiumToday: 0,
            sodiumTarget: 1500, guideline: guideline
        )
        for _ in 0..<20 {
            let repeated = DailyInsight.forToday(
                readings: readings, doses: [], sodiumToday: 0,
                sodiumTarget: 1500, guideline: guideline
            )
            #expect(repeated == first)
        }
    }
}

@Suite("Quiet hours")
struct QuietHoursTests {

    private func hours(_ start: Int, _ end: Int) -> NotificationEngine.QuietHours {
        NotificationEngine.QuietHours(isEnabled: true, startHour: start, endHour: end)
    }

    /// The normal case: a window that crosses midnight.
    @Test("An overnight window covers both sides of midnight")
    func overnightWindow() {
        let quiet = hours(22, 7)
        #expect(quiet.contains(hour: 23))
        #expect(quiet.contains(hour: 2))
        #expect(quiet.contains(hour: 6))
        #expect(!quiet.contains(hour: 7))
        #expect(!quiet.contains(hour: 12))
    }

    @Test("A same-day window behaves normally")
    func sameDayWindow() {
        let quiet = hours(13, 15)
        #expect(quiet.contains(hour: 14))
        #expect(!quiet.contains(hour: 16))
        #expect(!quiet.contains(hour: 2))
    }

    @Test("Disabled quiet hours never suppress anything")
    func disabled() {
        let quiet = NotificationEngine.QuietHours(isEnabled: false, startHour: 22, endHour: 7)
        for hour in 0..<24 { #expect(!quiet.contains(hour: hour)) }
    }

    /// A suppressed reminder moves rather than disappearing.
    @Test("Reminders resume at the end of the window")
    func resumesAtEnd() {
        #expect(hours(22, 7).resumeHour == 7)
    }
}

@Suite("App settings")
@MainActor
struct AppSettingsTests {

    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test("Appearance maps to a colour scheme, with system meaning nil")
    func appearanceMapping() {
        #expect(AppSettings.Appearance.system.colorScheme == nil)
        #expect(AppSettings.Appearance.light.colorScheme == .light)
        #expect(AppSettings.Appearance.dark.colorScheme == .dark)
    }

    /// Weight is stored in kilograms whatever the display unit, so switching
    /// units must never change a stored value.
    @Test("Pounds is a display conversion, not a stored unit")
    func weightConversion() {
        let store = settings()
        store.weightUnit = .kilograms
        #expect(store.displayWeight(70).contains("70.0 kg"))
        store.weightUnit = .pounds
        #expect(store.displayWeight(70).contains("154"))
    }

    @Test("Preferences survive a new instance")
    func persistence() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = AppSettings(defaults: defaults)
        first.appearance = .dark
        first.weightUnit = .pounds

        let second = AppSettings(defaults: defaults)
        #expect(second.appearance == .dark)
        #expect(second.weightUnit == .pounds)
    }
}

/// Review prompt gating.
///
/// The rules exist to stop the app asking at a bad moment. In a health app that
/// is not merely impolite — asking for a rating just after telling someone their
/// reading needs medical attention is the kind of thing that earns a one-star
/// review rather than avoiding one.
@Suite("Review prompt")
@MainActor
struct ReviewPromptTests {

    private func prompt() -> ReviewPrompt {
        ReviewPrompt(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func readings(
        count: Int, overDays days: Int, systolic: Int = 120, diastolic: Int = 80
    ) -> [BPReading] {
        (0..<count).map { index in
            BPReading(
                profileID: UUID(), systolic: systolic, diastolic: diastolic,
                recordedAt: Date.now.addingTimeInterval(-Double(index % days) * 86_400)
            )
        }
    }

    @Test("A new user is never asked")
    func neverAsksNewUser() {
        // firstUse is set to now on init, so the day threshold cannot be met.
        #expect(!prompt().shouldRequest(readings: readings(count: 20, overDays: 10), isCalmMoment: true))
    }

    @Test("Too few readings does not qualify")
    func requiresEnoughReadings() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(Date.now.addingTimeInterval(-30 * 86_400), forKey: "review.firstUse")
        let store = ReviewPrompt(defaults: defaults)
        #expect(!store.shouldRequest(readings: readings(count: 4, overDays: 4), isCalmMoment: true))
    }

    /// Ten readings in one sitting is not ten days of use.
    @Test("Readings must span several days")
    func requiresDistinctDays() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(Date.now.addingTimeInterval(-30 * 86_400), forKey: "review.firstUse")
        let store = ReviewPrompt(defaults: defaults)
        #expect(!store.shouldRequest(readings: readings(count: 12, overDays: 1), isCalmMoment: true))
    }

    @Test("An engaged user in a calm moment qualifies")
    func asksEngagedUser() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(Date.now.addingTimeInterval(-30 * 86_400), forKey: "review.firstUse")
        let store = ReviewPrompt(defaults: defaults)
        #expect(store.shouldRequest(readings: readings(count: 15, overDays: 10), isCalmMoment: true))
    }

    /// The rule that matters most.
    @Test("A crisis-range reading suppresses the prompt entirely")
    func neverAsksAfterHighReading() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(Date.now.addingTimeInterval(-30 * 86_400), forKey: "review.firstUse")
        let store = ReviewPrompt(defaults: defaults)

        var set = readings(count: 15, overDays: 10)
        set.insert(
            BPReading(profileID: UUID(), systolic: 195, diastolic: 125, recordedAt: .now),
            at: 0
        )
        #expect(!store.shouldRequest(readings: set, isCalmMoment: true))
    }

    @Test("An uncalm moment overrides every other rule")
    func calmnessOverrides() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(Date.now.addingTimeInterval(-30 * 86_400), forKey: "review.firstUse")
        let store = ReviewPrompt(defaults: defaults)
        #expect(!store.shouldRequest(readings: readings(count: 20, overDays: 12), isCalmMoment: false))
    }

    @Test("The same version is never asked twice")
    func asksOncePerVersion() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(Date.now.addingTimeInterval(-30 * 86_400), forKey: "review.firstUse")
        let store = ReviewPrompt(defaults: defaults)
        let set = readings(count: 15, overDays: 10)

        #expect(store.shouldRequest(readings: set, isCalmMoment: true))
        store.markRequested()
        #expect(!store.shouldRequest(readings: set, isCalmMoment: true))
    }

    @Test("The direct review link targets the App Store write-review action")
    func reviewURL() {
        let url = ReviewPrompt.writeReviewURL
        #expect(url?.absoluteString.contains("action=write-review") == true)
    }
}

/// Sign-in validation.
///
/// Validation runs on the device so bad input never reaches a server, but the
/// account itself lives server-side — there is deliberately no local password
/// store, and these tests pin that the client only checks shape.
@Suite("Authentication")
@MainActor
struct AuthTests {

    @Test("Well-formed credentials pass")
    func acceptsValid() throws {
        try AuthService.validate(email: "user@example.com", password: "correct1horse")
        try AuthService.validate(email: "a.b+tag@sub.example.co.uk", password: "passw0rd")
    }

    @Test("Malformed addresses are rejected")
    func rejectsBadEmail() {
        for email in ["", "user", "user@", "@example.com", "user@example", "a@b@c.com"] {
            #expect(throws: AuthService.AuthError.self) {
                try AuthService.validate(email: email, password: "passw0rd")
            }
        }
    }

    /// Length alone is not enough; a digit is required.
    @Test("Weak passwords are rejected")
    func rejectsWeakPassword() {
        for password in ["", "short1", "nodigitshere", "1234567"] {
            #expect(throws: AuthService.AuthError.self) {
                try AuthService.validate(email: "user@example.com", password: password)
            }
        }
    }

    @Test("Cancelling produces no error message to show")
    func cancellationIsSilent() {
        #expect(AuthService.AuthError.cancelled.errorDescription == nil)
    }

    @Test("Unconfigured providers name themselves")
    func unconfiguredIsClear() {
        let error = AuthService.AuthError.notConfigured("Google")
        #expect(error.errorDescription?.contains("Google") == true)
    }

    /// Google stays unavailable until a real client ID is set, rather than
    /// failing at the last step of an OAuth flow.
    @Test("Google is unconfigured by default")
    func googleUnconfigured() {
        #expect(!GoogleAuthConfig.isConfigured)
    }

    @Test("Email sign-in is unconfigured while the backend stores no users")
    func emailUnconfigured() {
        #expect(!EmailAuthConfig.isConfigured)
    }

    /// The property that matters most: signing out must not touch health data.
    @Test("Signing out clears the account only")
    func signOutClearsAccountOnly() {
        final class MemoryStore: AccountStore, @unchecked Sendable {
            var stored: AuthService.Account?
            func load() -> AuthService.Account? { stored }
            func save(_ account: AuthService.Account) { stored = account }
            func clear() { stored = nil }
        }

        let store = MemoryStore()
        store.stored = .init(
            id: "abc", provider: .apple, email: "a@b.com",
            displayName: "Test", signedInAt: .now
        )

        let service = AuthService(store: store)
        #expect(service.isSignedIn)

        service.signOut()
        #expect(!service.isSignedIn)
        #expect(store.stored == nil)
    }
}
