import Foundation

/// Mirrors the backend's `/entitlements` payload. The client never decides
/// what a user is allowed to do — it only renders what the server reports.
struct FeatureUsage: Codable, Hashable {
    let feature: String
    let used: Int
    let limit: Int?          // nil = unlimited
    let remaining: Int?
    let premiumOnly: Bool

    var isUnlimited: Bool { limit == nil }
    var isExhausted: Bool { (remaining ?? 1) <= 0 }

    /// "2 free AI scans available" / "1 free scan remaining" / "Premium Feature"
    func badge(noun: String, pluralNoun: String? = nil) -> String {
        if isUnlimited { return "Unlimited" }
        if premiumOnly { return "Premium Feature" }
        let left = remaining ?? 0
        if left == 0 { return "No \(pluralNoun ?? noun + "s") left" }
        let word = left == 1 ? noun : (pluralNoun ?? noun + "s")
        return used == 0 ? "\(left) free \(word) available" : "\(left) free \(word) remaining"
    }
}

struct Entitlements: Codable {
    let plan: String
    let periodStart: String
    let periodEnd: String
    let features: [String: FeatureUsage]

    var isPro: Bool { plan == "pro" }
    var foodScan: FeatureUsage { features["food_scan"] ?? .placeholder("food_scan") }
    var coach: FeatureUsage { features["coach"] ?? .placeholder("coach") }
    var mealPlan: FeatureUsage { features["meal_plan"] ?? .placeholder("meal_plan") }

    static let free = Entitlements(
        plan: "free", periodStart: "", periodEnd: "",
        features: ["food_scan": .placeholder("food_scan"),
                   "coach": .placeholder("coach"),
                   "meal_plan": .placeholder("meal_plan")]
    )
}

extension FeatureUsage {
    static func placeholder(_ name: String) -> FeatureUsage {
        FeatureUsage(feature: name, used: 0, limit: name == "meal_plan" ? 0 : 2,
                     remaining: name == "meal_plan" ? 0 : 2, premiumOnly: name == "meal_plan")
    }
}

/// The 402 body the backend returns when an allowance is spent.
struct PremiumRequired: Codable, Equatable {
    let feature: String
    let reason: String       // limit_reached | premium_only
    let usage: FeatureUsage?

    /// Which paywall copy to show. The offer should speak to the thing the
    /// user was just trying to do.
    var context: PaywallContext {
        switch feature {
        case "coach": .coach
        case "meal_plan": .mealPlan
        case "weekly_report": .report
        default: .foodScan
        }
    }
}

enum PaywallContext: String {
    case foodScan, coach, mealPlan, workout, brain, report, general

    /// Speaks to whatever the person just tried to do. A paywall that opens
    /// with a generic pitch after a specific action reads as a toll booth.
    var headline: String {
        switch self {
        case .foodScan: "You've used your free scans"
        case .coach:    "Your coach has more to say"
        case .mealPlan: "Meals planned around your day"
        case .workout:  "Sessions that adapt to you"
        case .brain:    "A coach that learns you"
        case .report:   "Your week, in one picture"
        case .general:  "A coach that actually knows you"
        }
    }

    var subhead: String {
        switch self {
        case .foodScan:
            "Scan anything, anytime — and every scan teaches the coach a little more about how you eat."
        case .coach:
            "Ask anything about your day and get an answer built from your own numbers, not general advice."
        case .mealPlan:
            "Built around the calories and protein you have left today, and the food you actually like."
        case .workout:
            "Sessions that follow your equipment and your last workout — with weights based on what you've really lifted."
        case .brain:
            "SnapCal notices your patterns and remembers what works for you, so week eight is far more useful than week one."
        case .report:
            "What moved, what didn't, and the one thing worth changing next week."
        case .general:
            "Most apps count calories. SnapCal learns your patterns and tells you what matters today."
        }
    }

    /// Three at most. A long list of ticks reads as filler and gets skimmed;
    /// three specific claims get read.
    var benefits: [PremiumBenefit] {
        switch self {
        case .foodScan:
            [.init(icon: "camera.viewfinder", title: "Unlimited scans",
                   detail: "Photo, barcode, voice or text — with an honest confidence range, not false precision."),
             .init(icon: "slider.horizontal.3", title: "Fix any portion",
                   detail: "One tap to correct, and it remembers your usual serving."),
             .init(icon: "chart.line.uptrend.xyaxis", title: "Trends that mean something",
                   detail: "Compared against your own baseline, not a generic target.")]

        case .coach, .brain:
            [.init(icon: "brain", title: "Remembers you",
                   detail: "Your routines, what you'll actually eat, and which advice has worked before."),
             .init(icon: "list.bullet.clipboard", title: "Two or three things a day",
                   detail: "Each with the reason behind it — never a wall of generic tips."),
             .init(icon: "moon.zzz", title: "Knows when to stay quiet",
                   detail: "Asks less on the days you've slept badly, instead of pushing harder.")]

        case .mealPlan:
            [.init(icon: "fork.knife", title: "Fits what's left of today",
                   detail: "Planned around your remaining calories, not a fresh blank day."),
             .init(icon: "heart.text.square", title: "Respects your food",
                   detail: "Allergies, diet and the things you've said you don't like."),
             .init(icon: "plus.circle", title: "One tap to log",
                   detail: "Macros already exact — no confirmation step.")]

        case .workout:
            [.init(icon: "figure.strengthtraining.traditional", title: "Built for your kit",
                   detail: "Full gym, dumbbells or nothing at all — and your time budget."),
             .init(icon: "arrow.up.right", title: "Real progression",
                   detail: "Weights come from what you've lifted, never a guess."),
             .init(icon: "bed.double", title: "Rest when you need it",
                   detail: "Four hard days running and it recommends recovery instead.")]

        case .report:
            [.init(icon: "calendar", title: "The week that was",
                   detail: "Weight trend, protein consistency, sessions done, sleep."),
             .init(icon: "lightbulb", title: "What SnapCal noticed",
                   detail: "The patterns behind the numbers, not just the numbers."),
             .init(icon: "target", title: "Next week's focus",
                   detail: "One thing to change, chosen from what actually moves for you.")]

        case .general:
            [.init(icon: "brain", title: "Learns your patterns",
                   detail: "When you eat, what works for you, where things slip — and gets better every week."),
             .init(icon: "camera.viewfinder", title: "Unlimited AI scans",
                   detail: "With a confidence range, because a photo can't see the oil."),
             .init(icon: "figure.run", title: "Coaching, not reminders",
                   detail: "Food, training, sleep and recovery — two or three things a day, each with a reason.")]
        }
    }
}

/// A single premium claim. `detail` is what makes it credible — a bare tick
/// list is skimmed, a specific sentence is read.
struct PremiumBenefit: Identifiable, Hashable {
    var id: String { title }
    let icon: String
    let title: String
    let detail: String
}

// MARK: - Coach

struct CoachMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    let role: String
    let content: String

    var isUser: Bool { role == "user" }

    enum CodingKeys: String, CodingKey { case role, content }
}

/// A concrete next meal resolved from the nutrition database — not a second AI
/// call. Macros are exact, so "Add to Diary" needs no confirmation step.
struct MealSuggestion: Codable, Identifiable, Hashable {
    var id: String { foodId }
    let foodId: String
    let name: String
    let slot: MealSlot
    let grams: Double
    let quantity: Double
    let unit: String
    let kcal100g: Double
    let protein100g: Double
    let carbs100g: Double
    let fat100g: Double
    let calories: Int
    let protein_g: Int
    let carbs_g: Int
    let fat_g: Int
    let reason: String

    enum CodingKeys: String, CodingKey {
        case foodId = "food_id", name, slot, grams, quantity, unit
        case kcal100g = "kcal_100g", protein100g = "protein_100g"
        case carbs100g = "carbs_100g", fat100g = "fat_100g"
        case calories, protein_g, carbs_g, fat_g, reason
    }

    /// Same shape the diary stores, so what the card shows is what gets saved.
    var asFoodItem: FoodItem {
        FoodItem(foodId: foodId, name: name, quantity: quantity, unit: unit, grams: grams,
                 kcal100g: kcal100g, protein100g: protein100g,
                 carbs100g: carbs100g, fat100g: fat100g,
                 confidence: 1, isEstimate: false)
    }
}

struct CoachAnswer: Codable {
    let answer: String
    let suggestion: MealSuggestion?
    let entitlements: Entitlements
    /// What the server decided the question was: meal_recommendation,
    /// workout_request, daily_plan, safety, and so on. Decides which card (if
    /// any) follows the reply — a safety answer must never carry one.
    let intent: String?
}

struct SuggestionResponse: Codable {
    let suggestion: MealSuggestion?
    let remaining: MacroTotal?
    let budget: Int?
}

// MARK: - Meal plan

struct PlannedMeal: Codable, Identifiable, Hashable {
    var id = UUID()
    let slot: String
    let name: String
    let grams: Double
    let kcal: Int
    let protein_g: Int
    let carbs_g: Int
    let fat_g: Int

    enum CodingKeys: String, CodingKey { case slot, name, grams, kcal, protein_g, carbs_g, fat_g }

    /// Converts a planned meal into a diary entry without another AI call.
    var asFoodItem: FoodItem {
        let g = max(grams, 1)
        return FoodItem(foodId: nil, name: name, quantity: 1, unit: "serving", grams: g,
                        kcal100g: Double(kcal) / g * 100,
                        protein100g: Double(protein_g) / g * 100,
                        carbs100g: Double(carbs_g) / g * 100,
                        fat100g: Double(fat_g) / g * 100,
                        confidence: 1, isEstimate: true)
    }
}

struct PlanDay: Codable, Identifiable, Hashable {
    var id: String { date }
    let date: String
    let meals: [PlannedMeal]

    var totalKcal: Int { meals.reduce(0) { $0 + $1.kcal } }
    var totalProtein: Int { meals.reduce(0) { $0 + $1.protein_g } }
}

struct MealPlan: Codable {
    let days: [PlanDay]
    let note: String?
    /// "remaining_today" when the plan covers only what's left of today.
    let plannedFor: String?
    let budgetKcal: Int?

    var isRestOfDay: Bool { plannedFor == "remaining_today" }

    enum CodingKeys: String, CodingKey {
        case days, note, plannedFor = "planned_for", budgetKcal = "budget_kcal"
    }
}

// MARK: - Weekly report

struct WeeklyReport: Codable {
    let weekStart: String
    let weightChangeKg: Double?
    let avgCalories: Int?
    let avgProteinG: Int?
    let proteinPctOfTarget: Int?
    let steps: Int
    let activeKcal: Int
    let daysLogged: Int
    let insight: String

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start", weightChangeKg = "weight_change_kg"
        case avgCalories = "avg_calories", avgProteinG = "avg_protein_g"
        case proteinPctOfTarget = "protein_pct_of_target"
        case steps, activeKcal = "active_kcal", daysLogged = "days_logged", insight
    }
}

// MARK: - Notifications

struct NotificationPrefs: Codable {
    var dailyCoach: Bool
    var morningHour: Int
    var morningMinute: Int
    var mealReminders: Bool
    var foodLogging: Bool
    var coachReminder: Bool
    var premiumOffers: Bool
    var permission: String

    enum CodingKeys: String, CodingKey {
        case dailyCoach = "daily_coach", morningHour = "morning_hour"
        case morningMinute = "morning_minute", mealReminders = "meal_reminders"
        case foodLogging = "food_logging", coachReminder = "coach_reminder"
        case premiumOffers = "premium_offers", permission
    }

    static let `default` = NotificationPrefs(
        dailyCoach: true, morningHour: 8, morningMinute: 0, mealReminders: false,
        foodLogging: false, coachReminder: false, premiumOffers: true, permission: "undetermined")
}

struct MorningMessage: Codable {
    let title: String
    let body: String
    let deeplink: String
}


// MARK: - Daily briefing

/// One of today's 1–3 priorities.
///
/// Every action carries a reason. The backend refuses to emit one without it,
/// and the UI should never render a card that has lost its "why" — an
/// instruction with no justification is just an app telling someone what to do.
struct PriorityAction: Codable, Identifiable, Hashable {
    let id: String
    let domain: String
    let action: String
    let reason: String
    let confidence: Double

    /// Icon per domain. Kept here rather than in the view so the mapping is
    /// in one place when new domains are added server-side.
    var icon: String {
        switch domain {
        case "nutrition":  "fork.knife"
        case "fitness":    "figure.strengthtraining.traditional"
        case "sleep":      "moon.zzz"
        case "recovery":   "heart.text.square"
        case "hydration":  "drop"
        case "activity":   "figure.walk"
        default:           "checkmark.circle"
        }
    }

}

struct DailyBriefing: Codable {
    let date: String
    /// recovery | maintenance | growth. An internal coaching decision — never
    /// render it as a score.
    let mode: String
    let headline: String
    let actions: [PriorityAction]
    /// Metrics with no data. Prompt to connect rather than showing a zero.
    let missing: [String]

    static let empty = DailyBriefing(
        date: "", mode: "maintenance",
        headline: "", actions: [], missing: []
    )
}

// MARK: - Personal Health Brain

struct BrainMemory: Codable, Identifiable, Hashable {
    let id: String
    let content: String
    let confidence: Double
    let evidenceCount: Int
    let userEdited: Bool

    enum CodingKeys: String, CodingKey {
        case id, content, confidence
        case evidenceCount = "evidence_count"
        case userEdited = "user_edited"
    }
}

struct BrainMemories: Codable {
    let layers: [String: [BrainMemory]]
    let labels: [String: String]
    let total: Int

    /// Ordered for display. Routines first — they're the most recognisable,
    /// which is what makes the whole screen feel accurate rather than creepy.
    var orderedLayers: [(label: String, memories: [BrainMemory])] {
        ["routine", "semantic", "preference", "procedural", "episodic"]
            .compactMap { key in
                guard let items = layers[key], !items.isEmpty else { return nil }
                return (labels[key] ?? key.capitalized, items)
            }
    }
}

struct LearnCycleResult: Codable {
    let outcomesMeasured: Int
    let memoriesAdded: Int
    let memoriesUpdated: Int
    let memoriesReinforced: Int
}


// MARK: - Structured workouts

struct PlannedExercise: Codable, Identifiable, Hashable {
    var id: String { exerciseName }
    let exerciseName: String
    let sets: Int
    /// A range like "8-12", or a hold like "30-45 sec". Never a single number —
    /// false precision on reps helps nobody.
    let reps: String
    let restSeconds: Int
    /// Only ever derived from weights this person has actually lifted. `nil`
    /// means no history, and `progressionNote` explains that.
    let suggestedWeightKg: Double?
    let progressionNote: String?
    let instructions: String
    let targets: String

    enum CodingKeys: String, CodingKey {
        case exerciseName = "exercise_name"
        case sets, reps
        case restSeconds = "rest_seconds"
        case suggestedWeightKg = "suggested_weight_kg"
        case progressionNote = "progression_note"
        case instructions, targets
    }
}

struct WorkoutPlan: Codable, Identifiable {
    let id: String?
    let workoutTitle: String
    let focus: String
    let durationMinutes: Int
    let warmup: [String]
    let exercises: [PlannedExercise]
    let optionalCardio: String?
    let cooldown: [String]
    let coachNote: String

    /// A recovery session is a real recommendation, not a failure to program
    /// one — the UI should say so rather than looking like an empty workout.
    var isRecovery: Bool { focus == "mobility" || focus == "cardio" }

    enum CodingKeys: String, CodingKey {
        case id
        case workoutTitle = "workout_title"
        case focus
        case durationMinutes = "duration_minutes"
        case warmup, exercises
        case optionalCardio = "optional_cardio"
        case cooldown
        case coachNote = "coach_note"
    }
}

/// A set the user has actually completed, ready to log.
struct CompletedSet: Identifiable, Hashable {
    let id = UUID()
    var exercise: String
    var setNumber: Int
    var reps: Int?
    var weightKg: Double?
    var done: Bool = false
}

// MARK: - Fitness onboarding

struct OnboardingOption: Codable, Identifiable, Hashable {
    var id: String { value }
    let value: String
    let label: String
}

struct OnboardingQuestion: Codable {
    let field: String
    let question: String
    let options: [OnboardingOption]
    let multiSelect: Bool
    let step: Int
    let total: Int
    let skippable: Bool
}

struct OnboardingState: Codable {
    let completed: Bool
    let next: OnboardingQuestion?
    let answered: Int
    let total: Int
    /// Only present for a first-time user; nil on return.
    let welcome: String?
}


// MARK: - Health onboarding

struct OnboardingField: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let label: String
    /// text | number | time | chips | chips_multi | toggle | slider | list
    let type: String
    let options: [OnboardingOption]?
    let placeholder: String?
    let optional: Bool?
    /// Shown under the field — several explain *why* we're asking, which is
    /// what makes the sensitive screens acceptable.
    let hint: String?
    let min: Double?
    let max: Double?
    let unit: String?

    var isOptional: Bool { optional ?? false }
}

struct OnboardingScreen: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let fields: [OnboardingField]
    let skippable: Bool
}

struct HealthOnboardingPlan: Codable {
    let screens: [OnboardingScreen]
    let currentIndex: Int
    /// **Never hardcode this.** It varies per user — someone who has connected
    /// Health and filled a profile sees fewer screens, and a bar reading
    /// "of 8" that ends at 5 looks broken.
    let totalScreens: Int
    let completed: Bool
}

// MARK: - First coach conversation

struct WelcomeTopic: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    /// Built from what onboarding already captured, so the coach goes deeper
    /// rather than asking the same questions again.
    let opener: String
}

struct CoachWelcome: Codable {
    /// Null once they have met — fall through to normal chat.
    let greeting: String?
    let knows: [String]
    let topics: [WelcomeTopic]
    let seen: Bool
}
