import SwiftData
import SwiftUI

@main
struct BPCoachApp: App {

    @State private var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private let stack: PersistenceController.Stack

    init() {
        // Never crash on launch. If the disk store cannot open, the stack falls
        // back to memory and the app says so rather than dying silently.
        let stack = PersistenceController.makeStack()
        self.stack = stack
        self._appModel = State(initialValue: AppModel(context: stack.container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(appModel.guidelines)
                .environment(appModel.health)
                .tint(Theme.accent)
                .preferredColorScheme(appModel.settings.appearance.colorScheme)
                .overlay(alignment: .top) {
                    if stack.isEphemeral { StorageWarningBanner() }
                }
                // Scheduled at launch, not from a screen.
                //
                // This used to run in HomeView's `.task`, which meant opening
                // the app straight to the Coach tab queued nothing at all — and
                // a notification that was never scheduled is indistinguishable
                // from one that failed to arrive.
                .task { await scheduleCheckIn() }
        }
        .modelContainer(stack.container)
        .onChange(of: scenePhase) { _, phase in
            // Rescheduled on the way out as well, so the queued question
            // reflects what the user just did rather than what was true when
            // they opened the app.
            if phase == .background {
                Task { await scheduleCheckIn() }
            }
        }
    }
}

extension BPCoachApp {
    /// Queues the daily check-in from whatever is currently stored.
    ///
    /// Reads directly rather than through a view's `@Query`: this has to happen
    /// whichever screen the app opens on, including none of them.
    @MainActor
    private func scheduleCheckIn() async {
        // Not before onboarding. Scheduling asks for notification permission,
        // and an iOS prompt on the very first launch — before the app has
        // explained what it would send — is both rude and the surest way to get
        // it declined permanently.
        guard appModel.hasCompletedOnboarding else { return }

        let context = stack.container.mainContext
        let profileID = appModel.activeProfile.id

        func fetch<T: PersistentModel>(_ type: T.Type) -> [T] {
            (try? context.fetch(FetchDescriptor<T>())) ?? []
        }

        let checkIn = CheckInPrompts.context(
            profileID: profileID,
            readings: fetch(BPReading.self),
            medications: fetch(Medication.self),
            doses: fetch(MedicationDose.self),
            lifestyle: fetch(LifestyleEntry.self),
            symptoms: fetch(SymptomEntry.self),
            appointments: fetch(Appointment.self)
        )

        await NotificationEngine.shared.scheduleDailyCheckIn(checkIn)
    }
}

/// Shown when persistence fell back to memory. Readings will not survive a
/// relaunch, and the user needs to know that before they rely on the app.
struct StorageWarningBanner: View {
    var body: some View {
        Label(
            "Storage unavailable — readings won't be saved after you close the app.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote.weight(.medium))
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.statusSevere)
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isStaticText)
    }
}
