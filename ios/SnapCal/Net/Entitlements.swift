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
    case foodScan, coach, mealPlan, report, general

    var headline: String {
        switch self {
        case .foodScan: "You've reached your free AI scans"
        case .coach:    "Your AI Coach is ready whenever you are"
        case .mealPlan: "Plan your meals effortlessly"
        case .report:   "See your week at a glance"
        case .general:  "Your Personal AI Weight-Loss Coach"
        }
    }

    var subhead: String {
        switch self {
        case .foodScan: "Upgrade to scan your meals anytime and automatically track your nutrition."
        case .coach:    "Get unlimited personalized weight-loss guidance with Premium."
        case .mealPlan: "Premium creates personalized meals around your calories, protein target and preferences."
        case .report:   "Premium turns your week of logging into one clear picture."
        case .general:  "Everything you need to make healthy progress easier."
        }
    }

    var benefits: [String] {
        switch self {
        case .foodScan:
            ["Unlimited AI Food Scans", "Calories & macros", "Portion editing", "Personalized nutrition insights"]
        case .coach:
            ["Unlimited AI Coach", "Personalized recommendations", "Daily guidance", "Progress-based coaching"]
        case .mealPlan:
            ["Personalized AI meal plans", "Built around your calorie & protein targets", "Respects your preferences", "Log a planned meal in one tap"]
        default:
            ["Unlimited AI Food Scans", "Unlimited AI Coach", "Personalized AI Meal Plans",
             "HealthKit-powered insights", "Personalized recommendations", "Weekly AI progress reports"]
        }
    }
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

    var tint: Color {
        switch domain {
        case "nutrition":  Theme.protein
        case "fitness":    Theme.accent
        case "sleep":      Theme.water
        case "recovery":   Theme.streak
        case "hydration":  Theme.water
        case "activity":   Theme.steps
        default:           Theme.accent
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
