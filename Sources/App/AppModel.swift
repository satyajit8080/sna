import Foundation
import Observation
import SwiftData

/// Shared app state: the active profile, onboarding status, and the services that
/// depend on them.
@Observable
@MainActor
final class AppModel {

    private(set) var activeProfile: UserProfile
    private(set) var profiles: [UserProfile] = []
    private(set) var hasCompletedOnboarding: Bool

    let guidelines: GuidelineEngine
    let settings: AppSettings
    let reviewPrompt: ReviewPrompt
    let auth: AuthService
    let health = HealthKitService()

    /// Real services when a backend URL is baked into the build; honest
    /// unconfigured stubs otherwise. Nothing between these two states — there
    /// is no mode where the app shows generated text it did not receive.
    let coach: AICoachService
    let foodProvider: FoodDataProvider
    /// Nil when no backend is configured, which is what disables food photo
    /// analysis in the UI rather than a separate flag.
    let foodVision: FoodVisionService?

    private let context: ModelContext
    private let defaults: UserDefaults
    private static let onboardingKey = "onboarding.complete"

    init(context: ModelContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
        self.guidelines = GuidelineEngine(defaults: defaults)
        self.settings = AppSettings(defaults: defaults)
        self.reviewPrompt = ReviewPrompt(defaults: defaults)
        self.auth = AuthService()
        self.hasCompletedOnboarding = defaults.bool(forKey: Self.onboardingKey)

        if let baseURL = BackendConfig.baseURL {
            self.coach = BackendCoachService(baseURL: baseURL)
            self.foodProvider = BackendFoodProvider(baseURL: baseURL)
            self.foodVision = FoodVisionService(baseURL: baseURL)
        } else {
            self.coach = UnconfiguredCoachService()
            self.foodProvider = UnconfiguredFoodDataProvider()
            self.foodVision = nil
        }

        let existing = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
        if let owner = existing.first(where: \.isOwner) {
            self.activeProfile = owner
            self.profiles = existing
        } else {
            let owner = UserProfile(name: "Me", kind: .owner)
            context.insert(owner)
            try? context.save()
            self.activeProfile = owner
            self.profiles = [owner]
        }
    }

    var contextEngine: AIContextEngine {
        AIContextEngine(guideline: guidelines.active)
    }

    var isMultiProfile: Bool { profiles.count > 1 }

    // MARK: - Profiles

    /// Refreshes tomorrow's check-in from the current state.
    ///
    /// Called when the app becomes active so the question reflects today rather
    /// than whenever it was last scheduled.
    func refreshDailyCheckIn(context: CheckInPrompts.Context) async {
        await NotificationEngine.shared.scheduleDailyCheckIn(context)
    }

    func setActive(_ profile: UserProfile) {
        activeProfile = profile
        Haptics.selection()
    }

    func renameOwner(to name: String) {
        activeProfile.name = name
        try? context.save()
    }

    @discardableResult
    func addProfile(name: String, kind: ProfileKind) -> UserProfile {
        let profile = UserProfile(name: name, kind: kind)
        context.insert(profile)
        try? context.save()
        refreshProfiles()
        return profile
    }

    /// Deleting a profile removes everything belonging to it. Leaving orphaned
    /// readings behind would let another profile's data surface in aggregate
    /// queries later.
    func deleteProfile(_ profile: UserProfile) {
        guard !profile.isOwner else { return }
        let id = profile.id
        deleteAllData(for: id)
        context.delete(profile)
        try? context.save()
        refreshProfiles()
        if activeProfile.id == id, let owner = profiles.first(where: \.isOwner) {
            activeProfile = owner
        }
    }

    func refreshProfiles() {
        profiles = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Self.onboardingKey)
    }

    // MARK: - Data management

    /// Removes every record belonging to a profile. Used by profile deletion and
    /// by the explicit "delete my data" control in Settings.
    func deleteAllData(for profileID: UUID) {
        deleteMatching(FetchDescriptor<BPReading>()) { $0.profileID == profileID }
        deleteMatching(FetchDescriptor<BPMeasurementSession>()) { $0.profileID == profileID }
        deleteMatching(FetchDescriptor<Medication>()) { $0.profileID == profileID }
        deleteMatching(FetchDescriptor<MedicationDose>()) { $0.profileID == profileID }
        deleteMatching(FetchDescriptor<LifestyleEntry>()) { $0.profileID == profileID }
        deleteMatching(FetchDescriptor<AIInsight>()) { $0.profileID == profileID }
        deleteMatching(FetchDescriptor<AIConversation>()) { $0.profileID == profileID }
        deleteMatching(FetchDescriptor<Appointment>()) { $0.profileID == profileID }
        deleteMatching(FetchDescriptor<SymptomEntry>()) { $0.profileID == profileID }
        deleteMatching(FetchDescriptor<ActivityEntry>()) { $0.profileID == profileID }

        // Documents own files on disk. Deleting the record alone would orphan
        // the file, leaving health data behind after a "delete my data" request.
        if let documents = try? context.fetch(FetchDescriptor<MedicalDocument>()) {
            for document in documents where document.profileID == profileID {
                if let fileName = document.fileName { DocumentStore.delete(fileName: fileName) }
                context.delete(document)
            }
        }

        try? context.save()
    }

    private func deleteMatching<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        where predicate: (T) -> Bool
    ) {
        guard let items = try? context.fetch(descriptor) else { return }
        for item in items where predicate(item) {
            context.delete(item)
        }
    }
}
