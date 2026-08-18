import Foundation
import SwiftData

@Model
final class Appointment {
    var id: UUID = UUID()
    var profileID: UUID = UUID()

    var doctorName: String = ""
    var specialty: String?
    var scheduledFor: Date = Date.now
    var location: String?
    var notes: String?

    /// Minutes before the appointment at which to remind. Multiple reminders are
    /// normal here — a week out to prepare, a day out to arrange travel.
    var reminderOffsets: [Int] = [7 * 24 * 60, 24 * 60]
    var remindersEnabled: Bool = true
    var wasAttended: Bool?

    init(
        profileID: UUID,
        doctorName: String,
        specialty: String? = nil,
        scheduledFor: Date,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.profileID = profileID
        self.doctorName = doctorName
        self.specialty = specialty
        self.scheduledFor = scheduledFor
        self.location = location
        self.notes = notes
    }

    var isUpcoming: Bool { scheduledFor > .now }

    /// Reminder times that are still in the future. A reminder whose moment has
    /// passed must not be scheduled — iOS would fire it immediately.
    func pendingReminderDates(now: Date = .now) -> [Date] {
        guard remindersEnabled else { return [] }
        return reminderOffsets
            .map { scheduledFor.addingTimeInterval(-Double($0) * 60) }
            .filter { $0 > now }
            .sorted()
    }
}
