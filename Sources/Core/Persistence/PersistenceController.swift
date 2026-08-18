import Foundation
import SwiftData

/// The SwiftData stack. Local-first: no CloudKit, no remote sync, no server.
///
/// Health data written here never leaves the device. If that ever changes it
/// requires an explicit, documented, privacy-reviewed decision — not a quiet
/// addition to a networking layer.
enum PersistenceController {

    static let schema = Schema([
        BPReading.self,
        BPMeasurementSession.self,
        UserProfile.self,
        Medication.self,
        MedicationDose.self,
        LifestyleEntry.self,
        AIInsight.self,
        AIConversation.self,
        AIMessage.self,
    ])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
