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
        Appointment.self,
        SymptomEntry.self,
        ActivityEntry.self,
        MedicalDocument.self,
        ExtractedValue.self,
    ])

    /// Result of building the stack, so the caller knows whether persistence is
    /// real. Falling back to memory silently would mean a user's readings
    /// disappear on relaunch with nothing to explain why.
    struct Stack {
        let container: ModelContainer
        let isEphemeral: Bool
    }

    /// True when running under XCTest or Swift Testing.
    ///
    /// A test host launches the app, which builds this stack in `init`. Writing
    /// to the real Application Support directory during tests is unnecessary and
    /// unreliable — on a fresh simulator that directory may not exist yet, which
    /// is exactly how this first surfaced.
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Application Support is not guaranteed to exist on a fresh install or a
    /// fresh simulator, so it is created rather than assumed.
    private static func storeURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appendingPathComponent("BPCoach.store")
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory || isRunningTests {
            return try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }

        let configuration = ModelConfiguration(schema: schema, url: try storeURL())
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Builds the stack, falling back to memory if the disk store cannot open.
    ///
    /// A crash on launch is the worst outcome for someone who just wants to log
    /// a reading. Degrading and saying so beats `fatalError`, and is far better
    /// than degrading quietly.
    static func makeStack() -> Stack {
        do {
            return Stack(container: try makeContainer(), isEphemeral: false)
        } catch {
            if let fallback = try? makeContainer(inMemory: true) {
                return Stack(container: fallback, isEphemeral: true)
            }
            // Both paths failed. An empty-schema container keeps the app
            // launchable so it can show the problem instead of dying.
            let empty = try! ModelContainer(
                for: Schema([]),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            return Stack(container: empty, isEphemeral: true)
        }
    }
}
