import Foundation
import SwiftData

/// A Rule-of-3 sitting: rest, then two or three readings about a minute apart.
///
/// The session average — not the individual readings — is what guidance is built
/// on, so it is stored explicitly rather than recomputed ad hoc.
@Model
final class BPMeasurementSession {
    var id: UUID = UUID()
    var profileID: UUID = UUID()
    var startedAt: Date = Date.now
    var completedAt: Date?
    var restSeconds: Int = 300
    var readingIDs: [UUID] = []

    var averageSystolic: Int?
    var averageDiastolic: Int?
    var averagePulse: Int?

    init(profileID: UUID, startedAt: Date = .now, restSeconds: Int = 300) {
        self.id = UUID()
        self.profileID = profileID
        self.startedAt = startedAt
        self.restSeconds = restSeconds
    }

    /// Standard practice discards the first of three readings — it runs high.
    /// With two, both are averaged.
    static func average(of readings: [BPReading]) -> (systolic: Int, diastolic: Int, pulse: Int?)? {
        guard !readings.isEmpty else { return nil }
        let ordered = readings.sorted { $0.recordedAt < $1.recordedAt }
        let used = ordered.count >= 3 ? Array(ordered.dropFirst()) : ordered

        let sys = used.map(\.systolic).reduce(0, +) / used.count
        let dia = used.map(\.diastolic).reduce(0, +) / used.count
        let pulses = used.compactMap(\.pulse)
        let pulse = pulses.isEmpty ? nil : pulses.reduce(0, +) / pulses.count
        return (sys, dia, pulse)
    }
}
