import Foundation

/// The bounded, structured payload sent to a coach service.
///
/// This is deliberately not the database. It is a summary, scoped to one profile,
/// capped in size, with every field optional so a sparse account degrades into a
/// smaller snapshot rather than a broken one.
struct BPContextSnapshot: Sendable {

    struct Reading: Sendable, Equatable {
        let systolic: Int
        let diastolic: Int
        let pulse: Int?
        let recordedAt: Date
        let timeOfDay: String
        let source: String
        let category: String
        let notes: String?
    }

    struct Averages: Sendable {
        let days: Int
        let systolic: Int
        let diastolic: Int
        let count: Int
    }

    struct MedicationSummary: Sendable {
        let name: String
        let dose: String
        let frequency: String
        let adherencePercent: Double?
    }

    struct LifestyleSummary: Sendable {
        let kind: String
        let total: Double
        let unit: String
        let isEstimate: Bool
    }

    let generatedAt: Date
    let guidelineName: String
    /// First name only, so the coach can address the person naturally.
    ///
    /// This does leave the device. It is the one identifying field that does,
    /// it is a first name rather than a full one, and the app's privacy copy
    /// says so — a coach that cannot use your name reads like a form.
    let firstName: String?
    /// What the person usually does for exercise and when, so a reading taken
    /// soon after can be recognised rather than treated as unexplained.
    var activityRoutine: String?

    var recentReadings: [Reading] = []
    var averages: [Averages] = []
    var variabilitySD: Double?
    var morningVsEvening: (morning: Int, evening: Int)?
    var medications: [MedicationSummary] = []
    var lifestyle: [LifestyleSummary] = []
    var stepsToday: Int?
    var restingHeartRate: Int?

    /// True when there genuinely is not enough here to say anything useful.
    var isTooSparse: Bool { recentReadings.count < 3 }
}

/// Builds the snapshot.
///
/// Three rules govern this type:
/// 1. Never dump the database — the payload is capped and summarised.
/// 2. Never cross profiles — everything is filtered by `profileID` at the source.
/// 3. Never fabricate — absent data is absent, not defaulted to zero.
@MainActor
struct AIContextEngine {

    /// Cap on individual readings included. Enough for the model to see a pattern,
    /// far short of a data dump.
    static let readingLimit = 30

    let guideline: BPGuideline

    func makeSnapshot(
        profileID: UUID,
        firstName: String? = nil,
        activityRoutine: String? = nil,
        readings: [BPReading],
        medications: [Medication],
        doses: [MedicationDose],
        lifestyle: [LifestyleEntry],
        healthSnapshot: HealthKitService.ActivitySnapshot? = nil,
        now: Date = .now
    ) -> BPContextSnapshot {

        // Profile isolation is enforced here, at the boundary, not by the caller.
        let ownReadings = readings
            .filter { $0.profileID == profileID }
            .sorted { $0.recordedAt > $1.recordedAt }

        var snapshot = BPContextSnapshot(
            generatedAt: now,
            guidelineName: guideline.displayName,
            firstName: firstName,
            activityRoutine: activityRoutine
        )

        snapshot.recentReadings = ownReadings.prefix(Self.readingLimit).map { reading in
            BPContextSnapshot.Reading(
                systolic: reading.systolic,
                diastolic: reading.diastolic,
                pulse: reading.pulse,
                recordedAt: reading.recordedAt,
                timeOfDay: reading.timeOfDay.label,
                source: reading.source.label,
                category: guideline.category(for: reading).label,
                notes: reading.notes
            )
        }

        snapshot.averages = [7, 30, 90].compactMap { days in
            guard let avg = BPStatistics.homeAverage(ownReadings, days: days, now: now) else {
                return nil
            }
            return BPContextSnapshot.Averages(
                days: days,
                systolic: avg.systolic,
                diastolic: avg.diastolic,
                count: avg.count
            )
        }

        snapshot.variabilitySD = BPStatistics.variability(ownReadings)?.systolicSD

        if let comparison = BPStatistics.morningVsEvening(ownReadings) {
            snapshot.morningVsEvening = (comparison.first.systolic, comparison.second.systolic)
        }

        snapshot.medications = medications
            .filter { $0.profileID == profileID && !$0.isArchived }
            .map { medication in
                let own = doses.filter { $0.medicationID == medication.id && $0.profileID == profileID }
                return BPContextSnapshot.MedicationSummary(
                    name: medication.name,
                    dose: medication.dose,
                    frequency: medication.frequency.label,
                    adherencePercent: MedicationEngine.adherence(for: own, now: now).percentage
                )
            }

        let ownLifestyle = lifestyle.filter { $0.profileID == profileID }
        snapshot.lifestyle = Dictionary(grouping: ownLifestyle, by: \.kind)
            .map { kind, entries in
                BPContextSnapshot.LifestyleSummary(
                    kind: kind.label,
                    total: entries.reduce(0) { $0 + $1.value },
                    unit: entries.first?.unit ?? "",
                    isEstimate: entries.contains(where: \.isEstimate)
                )
            }

        snapshot.stepsToday = healthSnapshot?.steps
        snapshot.restingHeartRate = healthSnapshot?.restingHeartRate

        return snapshot
    }
}
