import Foundation
import StoreKit
import SwiftUI

/// Decides when to ask for an App Store review.
///
/// `requestReview` is a *request* — iOS shows the prompt at most three times a
/// year and silently ignores the rest, so spending one badly is expensive. The
/// rules here are deliberately conservative:
///
/// - Ask only once the app has demonstrably been useful: enough readings, across
///   enough separate days, over enough time.
/// - Never ask on the back of a distressing moment. A crisis-range reading is
///   the worst possible time.
/// - Never ask twice for the same app version.
///
/// The second point matters most in a health app. Prompting someone who has just
/// been told to re-measure and call their doctor is tone-deaf, and it earns a
/// one-star review rather than avoiding one.
@Observable
@MainActor
final class ReviewPrompt {

    /// Readings before the app has plausibly proved its worth.
    private static let minimumReadings = 10
    /// Separate days, so ten readings in one sitting does not qualify.
    private static let minimumDistinctDays = 5
    /// Days since first launch, so a burst of setup activity does not qualify.
    private static let minimumDaysSinceFirstUse = 7

    private let defaults: UserDefaults
    private let firstUseKey = "review.firstUse"
    private let promptedVersionKey = "review.promptedVersion"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: firstUseKey) == nil {
            defaults.set(Date.now, forKey: firstUseKey)
        }
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var hasPromptedThisVersion: Bool {
        defaults.string(forKey: promptedVersionKey) == currentVersion
    }

    private var daysSinceFirstUse: Int {
        guard let first = defaults.object(forKey: firstUseKey) as? Date else { return 0 }
        return Calendar.current.dateComponents([.day], from: first, to: .now).day ?? 0
    }

    /// Whether now is a reasonable moment to ask.
    ///
    /// `isCalmMoment` is the caller's judgement: pass false anywhere the user
    /// may be worried, and the prompt is skipped whatever the other rules say.
    func shouldRequest(readings: [BPReading], isCalmMoment: Bool) -> Bool {
        guard isCalmMoment,
              !hasPromptedThisVersion,
              daysSinceFirstUse >= Self.minimumDaysSinceFirstUse,
              readings.count >= Self.minimumReadings
        else { return false }

        let distinctDays = Set(readings.map { Calendar.current.startOfDay(for: $0.recordedAt) })
        guard distinctDays.count >= Self.minimumDistinctDays else { return false }

        // Never ask on the back of a reading that needed safety guidance.
        if let latest = readings.max(by: { $0.recordedAt < $1.recordedAt }),
           SafetyEngine.assess(latest).urgency > .none {
            return false
        }

        return true
    }

    /// Marks this version as asked, whether or not iOS actually showed anything.
    /// The system may suppress the prompt, and asking again would not help.
    func markRequested() {
        defaults.set(currentVersion, forKey: promptedVersionKey)
    }

    /// Opens the App Store review page directly, for the explicit "Rate BP Coach"
    /// button in Help & Support where the user asked for it.
    static var writeReviewURL: URL? {
        URL(string: "https://apps.apple.com/app/id6801412727?action=write-review")
    }
}

/// Attaches the review request to a view, gated by the rules above.
struct ReviewPromptModifier: ViewModifier {
    @Environment(\.requestReview) private var requestReview
    let prompt: ReviewPrompt
    let readings: [BPReading]
    let isCalmMoment: Bool

    func body(content: Content) -> some View {
        content.task {
            // A short delay so the prompt does not collide with the screen
            // appearing, which makes it feel like an interruption.
            try? await Task.sleep(for: .seconds(2))
            guard prompt.shouldRequest(readings: readings, isCalmMoment: isCalmMoment) else {
                return
            }
            prompt.markRequested()
            requestReview()
        }
    }
}

extension View {
    /// Requests a review only when the moment is calm and the app has earned it.
    func reviewPrompt(
        _ prompt: ReviewPrompt,
        readings: [BPReading],
        isCalmMoment: Bool
    ) -> some View {
        modifier(ReviewPromptModifier(
            prompt: prompt, readings: readings, isCalmMoment: isCalmMoment
        ))
    }
}
