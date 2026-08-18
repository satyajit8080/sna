import Foundation
import HealthKit
import Observation

/// HealthKit bridge.
///
/// Data flows exactly one way: HealthKit → BP Coach → SwiftData. Nothing here
/// transmits health data anywhere. There is no networking in this file and there
/// must not be; adding a remote sync would require an explicit, documented,
/// privacy-reviewed decision.
///
/// Owner isolation: HealthKit belongs to the device owner profile. Every entry
/// point checks `ProfileKind.canUseHealthKit` and refuses otherwise, so a spouse
/// or parent profile can never inherit the owner's Health data.
@Observable
@MainActor
final class HealthKitService {

    enum HealthKitError: LocalizedError {
        case unavailable
        case notOwnerProfile
        case missingUsageDescription(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Health data is not available on this device."
            case .notOwnerProfile:
                "Apple Health is only connected to the device owner's profile. Other profiles use readings you enter yourself."
            case .missingUsageDescription(let key):
                "This build cannot connect to Apple Health: \(key) is missing from its configuration."
            }
        }
    }

    /// iOS terminates the process outright — no catchable error — if HealthKit
    /// authorization is requested while the required purpose strings are absent
    /// from Info.plist. Checking first turns a hard crash into a message.
    ///
    /// `NSHealthShareUsageDescription` covers reading, `NSHealthUpdateUsageDescription`
    /// covers writing. Requesting both without both strings is fatal.
    static func missingUsageDescriptionKey(bundle: Bundle = .main) -> String? {
        for key in ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"] {
            let value = bundle.object(forInfoDictionaryKey: key) as? String
            if value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                return key
            }
        }
        return nil
    }

    private func hasUsageDescription(_ key: String, bundle: Bundle = .main) -> Bool {
        let value = bundle.object(forInfoDictionaryKey: key) as? String
        return !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// True when the build can write readings back to Health. Surfaced in
    /// Settings so a reduced build is visible rather than mysterious.
    var canWriteToHealth: Bool {
        hasUsageDescription("NSHealthUpdateUsageDescription")
    }

    struct ActivitySnapshot: Equatable, Sendable {
        var steps: Int?
        var activeEnergyKilocalories: Int?
        var restingHeartRate: Int?
        var hrv: Double?
        var sleepMinutes: Int?
        var weightKilograms: Double?

        var isEmpty: Bool {
            steps == nil && activeEnergyKilocalories == nil && restingHeartRate == nil
                && hrv == nil && sleepMinutes == nil && weightKilograms == nil
        }
    }

    private(set) var isAvailable = HKHealthStore.isHealthDataAvailable()
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var snapshot = ActivitySnapshot()

    /// HealthKit never reports read-denial, so authorization status cannot be
    /// branched on. `hasReturnedData` is the honest proxy: no data plus a request
    /// already made almost always means permission was refused.
    private(set) var hasRequestedAuthorization: Bool {
        get { defaults.bool(forKey: "healthkit.requested") }
        set { defaults.set(newValue, forKey: "healthkit.requested") }
    }

    private(set) var hasReturnedData: Bool {
        get { defaults.bool(forKey: "healthkit.hasData") }
        set { defaults.set(newValue, forKey: "healthkit.hasData") }
    }

    private let store = HKHealthStore()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Types

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKQuantityType(.bloodPressureSystolic),
            HKQuantityType(.bloodPressureDiastolic),
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyMass),
            HKCategoryType(.sleepAnalysis),
        ]
        types.insert(HKCorrelationType(.bloodPressure))
        return types
    }

    /// Writing is limited to blood pressure the user entered here. Nothing else
    /// is written back to Health.
    private var writeTypes: Set<HKSampleType> {
        [
            HKQuantityType(.bloodPressureSystolic),
            HKQuantityType(.bloodPressureDiastolic),
        ]
    }

    // MARK: - Authorization

    /// Read-only authorization. This is what onboarding asks for.
    ///
    /// `_throwIfAuthorizationDisallowedForSharing` is a HealthKit validator that
    /// raises an Objective-C exception — uncatchable from Swift, so it kills the
    /// process. It only runs for the *share* list. Asking for read access alone
    /// cannot reach it, so first run cannot crash regardless of how the bundle
    /// is configured.
    ///
    /// Write access is requested separately, and only when the user actually
    /// chooses to save a reading back to Health.
    @discardableResult
    func requestReadAuthorization(for profile: UserProfile) async throws -> Bool {
        guard isAvailable else { throw HealthKitError.unavailable }
        guard profile.kind.canUseHealthKit else { throw HealthKitError.notOwnerProfile }
        guard hasUsageDescription("NSHealthShareUsageDescription") else {
            throw HealthKitError.missingUsageDescription("NSHealthShareUsageDescription")
        }

        hasRequestedAuthorization = true
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func requestAuthorization(for profile: UserProfile) async throws -> Bool {
        guard isAvailable else { throw HealthKitError.unavailable }
        guard profile.kind.canUseHealthKit else { throw HealthKitError.notOwnerProfile }

        // Reading requires NSHealthShareUsageDescription. Without it HealthKit
        // raises an Objective-C exception that Swift cannot catch, so the check
        // has to happen before the call.
        if !hasUsageDescription("NSHealthShareUsageDescription") {
            lastError = "Missing NSHealthShareUsageDescription"
            throw HealthKitError.missingUsageDescription("NSHealthShareUsageDescription")
        }

        // Writing requires NSHealthUpdateUsageDescription, validated separately
        // by HealthKit in _throwIfAuthorizationDisallowedForSharing. If it is
        // absent, request read access only: losing the ability to write back to
        // Health is a far better outcome than terminating the app.
        let canShare = hasUsageDescription("NSHealthUpdateUsageDescription")
        if !canShare {
            lastError = "Missing NSHealthUpdateUsageDescription — reading only."
        }

        hasRequestedAuthorization = true
        do {
            try await store.requestAuthorization(
                toShare: canShare ? writeTypes : [],
                read: readTypes
            )
            if canShare { lastError = nil }
            return true
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Reading blood pressure

    /// Blood pressure lives in HealthKit as a correlation of two quantity
    /// samples. Reading either one alone would silently drop the pairing.
    func fetchBloodPressure(
        for profile: UserProfile,
        since startDate: Date
    ) async throws -> [(systolic: Int, diastolic: Int, date: Date, uuid: String)] {

        guard isAvailable else { throw HealthKitError.unavailable }
        guard profile.kind.canUseHealthKit else { throw HealthKitError.notOwnerProfile }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil)
        let correlationType = HKCorrelationType(.bloodPressure)

        let samples: [HKCorrelation] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: correlationType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results as? [HKCorrelation]) ?? [])
                }
            }
            store.execute(query)
        }

        let unit = HKUnit.millimeterOfMercury()
        let mapped = samples.compactMap { correlation -> (Int, Int, Date, String)? in
            let systolicType = HKQuantityType(.bloodPressureSystolic)
            let diastolicType = HKQuantityType(.bloodPressureDiastolic)

            guard
                let s = correlation.objects(for: systolicType).first as? HKQuantitySample,
                let d = correlation.objects(for: diastolicType).first as? HKQuantitySample
            else { return nil }

            return (
                Int(s.quantity.doubleValue(for: unit).rounded()),
                Int(d.quantity.doubleValue(for: unit).rounded()),
                correlation.startDate,
                correlation.uuid.uuidString
            )
        }

        if !mapped.isEmpty { hasReturnedData = true }
        lastSyncedAt = .now
        return mapped
    }

    // MARK: - Writing blood pressure

    func save(reading: BPReading, for profile: UserProfile) async throws {
        guard isAvailable else { throw HealthKitError.unavailable }
        guard profile.kind.canUseHealthKit else { throw HealthKitError.notOwnerProfile }
        guard hasUsageDescription("NSHealthUpdateUsageDescription") else {
            throw HealthKitError.missingUsageDescription("NSHealthUpdateUsageDescription")
        }

        let unit = HKUnit.millimeterOfMercury()
        let systolic = HKQuantitySample(
            type: HKQuantityType(.bloodPressureSystolic),
            quantity: HKQuantity(unit: unit, doubleValue: Double(reading.systolic)),
            start: reading.recordedAt,
            end: reading.recordedAt
        )
        let diastolic = HKQuantitySample(
            type: HKQuantityType(.bloodPressureDiastolic),
            quantity: HKQuantity(unit: unit, doubleValue: Double(reading.diastolic)),
            start: reading.recordedAt,
            end: reading.recordedAt
        )
        let correlation = HKCorrelation(
            type: HKCorrelationType(.bloodPressure),
            start: reading.recordedAt,
            end: reading.recordedAt,
            objects: [systolic, diastolic]
        )
        try await store.save(correlation)
        reading.healthKitUUID = correlation.uuid.uuidString
    }

    /// Saves a reading to Health, requesting write authorization first if the
    /// bundle supports it.
    ///
    /// Every path that could reach HealthKit's sharing validator goes through
    /// here, and it returns early rather than calling into HealthKit when the
    /// write purpose string is absent.
    @discardableResult
    func saveRequestingAuthorizationIfNeeded(
        reading: BPReading,
        for profile: UserProfile
    ) async throws -> Bool {
        guard isAvailable, profile.kind.canUseHealthKit else { return false }
        guard hasUsageDescription("NSHealthUpdateUsageDescription") else {
            lastError = "This build cannot write to Health."
            return false
        }

        do {
            try await store.requestAuthorization(toShare: writeTypes, read: [])
            try await save(reading: reading, for: profile)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Context metrics

    func refreshSnapshot(for profile: UserProfile) async {
        guard isAvailable, profile.kind.canUseHealthKit else { return }
        do {
            async let steps = sumToday(HKQuantityType(.stepCount), unit: .count())
            async let energy = sumToday(HKQuantityType(.activeEnergyBurned), unit: .kilocalorie())
            async let restingHR = latest(
                HKQuantityType(.restingHeartRate),
                unit: .count().unitDivided(by: .minute())
            )
            async let hrv = latest(
                HKQuantityType(.heartRateVariabilitySDNN),
                unit: .secondUnit(with: .milli)
            )
            async let weight = latest(HKQuantityType(.bodyMass), unit: .gramUnit(with: .kilo))
            async let sleep = sleepMinutesLastNight()

            snapshot = ActivitySnapshot(
                steps: try await steps.map { Int($0.rounded()) },
                activeEnergyKilocalories: try await energy.map { Int($0.rounded()) },
                restingHeartRate: try await restingHR.map { Int($0.rounded()) },
                hrv: try await hrv,
                sleepMinutes: try await sleep,
                weightKilograms: try await weight
            )
            if !snapshot.isEmpty { hasReturnedData = true }
            lastSyncedAt = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Asleep minutes since 6pm yesterday. Sleep *stages* are not reliably
    /// measurable from a phone, so only total asleep time is reported — inventing
    /// REM and deep figures would be presenting a guess as a measurement.
    private func sleepMinutesLastNight() async throws -> Int? {
        let calendar = Calendar.current
        guard let start = calendar.date(
            byAdding: .hour, value: -18, to: calendar.startOfDay(for: .now)
        ) else { return nil }

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: start, end: nil),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (results as? [HKCategorySample]) ?? []) }
            }
            store.execute(query)
        }

        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]

        let seconds = samples
            .filter { asleepValues.contains($0.value) }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }

        return seconds > 0 ? Int(seconds / 60) : nil
    }

    /// Imports blood pressure from Health into the local store, skipping anything
    /// already present. Returns how many new readings were added.
    ///
    /// Deduplication is by HealthKit sample UUID: re-running an import must never
    /// double-count, because duplicated readings would silently distort averages.
    func importBloodPressure(
        for profile: UserProfile,
        since startDate: Date,
        existing: [BPReading],
        insert: (BPReading) -> Void
    ) async throws -> Int {

        let samples = try await fetchBloodPressure(for: profile, since: startDate)
        let knownUUIDs = Set(existing.compactMap(\.healthKitUUID))

        var imported = 0
        for sample in samples where !knownUUIDs.contains(sample.uuid) {
            guard BPReading.isPlausible(systolic: sample.systolic, diastolic: sample.diastolic)
            else { continue }

            let reading = BPReading(
                profileID: profile.id,
                systolic: sample.systolic,
                diastolic: sample.diastolic,
                recordedAt: sample.date,
                source: .healthKit
            )
            reading.healthKitUUID = sample.uuid
            insert(reading)
            imported += 1
        }
        lastSyncedAt = .now
        return imported
    }

    private func sumToday(_ type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        let start = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit)) }
            }
            store.execute(query)
        }
    }

    private func latest(_ type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, results, error in
                if let error { continuation.resume(throwing: error) }
                else {
                    let sample = (results?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                    continuation.resume(returning: sample)
                }
            }
            store.execute(query)
        }
    }
}
