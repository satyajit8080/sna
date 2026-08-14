import Foundation

// MARK: - Analysis

struct FoodItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var foodId: String?
    var name: String
    var quantity: Double
    var unit: String
    var grams: Double
    var kcal100g: Double
    var protein100g: Double
    var carbs100g: Double
    var fat100g: Double
    var confidence: Double?
    var isEstimate: Bool

    // Macros are derived, never stored — this is why a quantity edit costs zero AI calls.
    var calories: Int { Int((grams * kcal100g / 100).rounded()) }
    var protein:  Int { Int((grams * protein100g / 100).rounded()) }
    var carbs:    Int { Int((grams * carbs100g / 100).rounded()) }
    var fat:      Int { Int((grams * fat100g / 100).rounded()) }

    var gramsPerUnit: Double { quantity > 0 ? grams / quantity : grams }

    /// Local recompute on stepper changes. No network, no model.
    mutating func setQuantity(_ q: Double) {
        let per = gramsPerUnit
        quantity = max(0.25, q)
        grams = (unit == "g") ? quantity : (per * quantity).rounded()
    }

    enum CodingKeys: String, CodingKey {
        case foodId = "food_id", name, quantity, unit, grams
        case kcal100g = "kcal_100g", protein100g = "protein_100g"
        case carbs100g = "carbs_100g", fat100g = "fat_100g"
        case confidence, isEstimate = "is_estimate"
    }
}

struct MacroTotal: Codable, Hashable {
    var calories: Int
    var protein_g: Int
    var carbs_g: Int
    var fat_g: Int

    static let zero = MacroTotal(calories: 0, protein_g: 0, carbs_g: 0, fat_g: 0)
}

struct AnalysisResponse: Codable {
    var foods: [FoodItem]
    var total: MacroTotal
    var confidence: Double
    var assumptions: [String]
    var isEstimate: Bool
    var disclaimer: String
    var cached: Bool?

    enum CodingKeys: String, CodingKey {
        case foods, total, confidence, assumptions
        case isEstimate = "is_estimate", disclaimer, cached
    }
}

// MARK: - Dashboard

enum MealSlot: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }
    var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snacks"
        }
    }
    var icon: String {
        switch self {
        case .breakfast: "sunrise.fill"
        case .lunch: "sun.max.fill"
        case .dinner: "moon.stars.fill"
        case .snack: "leaf.fill"
        }
    }
    /// Sensible default so the user rarely has to pick.
    static func suggested(at date: Date = .now) -> MealSlot {
        switch Calendar.current.component(.hour, from: date) {
        case 4..<11: .breakfast
        case 11..<16: .lunch
        case 16..<22: .dinner
        default: .snack
        }
    }
}

struct Meal: Codable, Identifiable, Hashable {
    var id: String
    var slot: MealSlot
    var calories: Int
    var protein_g: Int
    var carbs_g: Int
    var fat_g: Int
    var items: [FoodItem]
    var note: String?
    var aiConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case id, slot, calories, protein_g, carbs_g, fat_g, items, note
        case aiConfidence = "ai_confidence"
    }
}

struct Targets: Codable, Hashable {
    var calories: Int
    var protein_g: Int
    var carbs_g: Int
    var fat_g: Int
    var water_ml: Int
}

struct Dashboard: Codable {
    var date: String
    var targets: Targets
    var consumed: MacroTotal
    var remaining: MacroTotal
    var waterMl: Int
    var currentWeightKg: Double?
    var streakDays: Int
    var meals: [Meal]

    enum CodingKeys: String, CodingKey {
        case date, targets, consumed, remaining, meals
        case waterMl = "water_ml", currentWeightKg = "current_weight_kg", streakDays = "streak_days"
    }

    static let placeholder = Dashboard(
        date: "", targets: Targets(calories: 2000, protein_g: 140, carbs_g: 210, fat_g: 60, water_ml: 2500),
        consumed: .zero, remaining: .zero, waterMl: 0, currentWeightKg: nil, streakDays: 0, meals: []
    )
}

// MARK: - Profile / onboarding

struct ProfileDraft: Codable {
    var name = ""
    var birthYear = Calendar.current.component(.year, from: .now) - 30
    var sex = "female"
    var heightCm: Double = 165
    var startWeightKg: Double = 70
    var goalWeightKg: Double = 63
    var goal = "lose"
    var activityLevel = "light"
    var units = "metric"
    var country: String?

    enum CodingKeys: String, CodingKey {
        case name, sex, goal, units, country
        case birthYear = "birth_year", heightCm = "height_cm"
        case startWeightKg = "start_weight_kg", goalWeightKg = "goal_weight_kg"
        case activityLevel = "activity_level"
    }
}

struct TargetsResponse: Codable {
    var targets: ComputedTargets
    var projectedWeeks: Int?
    enum CodingKeys: String, CodingKey { case targets, projectedWeeks = "projected_weeks" }
}

struct ComputedTargets: Codable {
    var bmr: Int, tdee: Int, calories: Int
    var protein_g: Int, carbs_g: Int, fat_g: Int, water_ml: Int
}

// MARK: - Subscription / usage

struct Quota: Codable {
    var plan: String
    var used: Int
    var limit: Int?
    var remaining: Int?
    var isPro: Bool { plan == "pro" }
}

struct SubscriptionStatus: Codable {
    var plan: String
    var expiresAt: Date?
    var quota: Quota
    enum CodingKeys: String, CodingKey { case plan, expiresAt = "expires_at", quota }
}

// MARK: - History / weight

struct DayNutrition: Codable, Identifiable {
    var date: String
    var calories: Int
    var protein_g: Int
    var carbs_g: Int
    var fat_g: Int
    var id: String { date }
}

struct WeightPoint: Codable, Identifiable {
    var loggedOn: String
    var weightKg: Double
    var id: String { loggedOn }
    enum CodingKeys: String, CodingKey { case loggedOn = "logged_on", weightKg = "weight_kg" }
}

struct WeightSeries: Codable {
    var startWeightKg: Double?
    var goalWeightKg: Double?
    var currentWeightKg: Double?
    var logs: [WeightPoint]
    enum CodingKeys: String, CodingKey {
        case startWeightKg = "start_weight_kg", goalWeightKg = "goal_weight_kg"
        case currentWeightKg = "current_weight_kg", logs
    }
}

struct History: Codable {
    var range: String
    var nutrition: [DayNutrition]
    var weight: [WeightPoint]
    var averages: MacroTotal
    var daysLogged: Int
    enum CodingKeys: String, CodingKey {
        case range, nutrition, weight, averages, daysLogged = "days_logged"
    }
}
