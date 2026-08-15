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

/// Lets a plain String drive `.sheet(item:)` for the guest prompt.
extension String: @retroactive Identifiable {
    public var id: String { self }
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

    /// Read-only sample shown in guest mode. North American meals, realistic
    /// numbers — the point is to show what a used app looks like.
    static let guestSample = Dashboard(
        date: "", targets: Targets(calories: 2100, protein_g: 150, carbs_g: 230, fat_g: 65, water_ml: 2500),
        consumed: MacroTotal(calories: 1240, protein_g: 88, carbs_g: 121, fat_g: 42),
        remaining: MacroTotal(calories: 860, protein_g: 62, carbs_g: 109, fat_g: 23),
        waterMl: 1500, currentWeightKg: 78.5, streakDays: 4,
        meals: [
            Meal(id: "sample-1", slot: .breakfast, calories: 335, protein_g: 20, carbs_g: 38, fat_g: 11,
                 items: [
                    FoodItem(foodId: nil, name: "Scrambled eggs", quantity: 2, unit: "egg", grams: 110,
                             kcal100g: 141, protein100g: 10, carbs100g: 1.5, fat100g: 10.5,
                             confidence: 1, isEstimate: false),
                    FoodItem(foodId: nil, name: "Oatmeal", quantity: 1, unit: "bowl", grams: 220,
                             kcal100g: 84, protein100g: 3, carbs100g: 15, fat100g: 1.7,
                             confidence: 1, isEstimate: false),
                 ], note: nil, aiConfidence: nil),
            Meal(id: "sample-2", slot: .lunch, calories: 520, protein_g: 41, carbs_g: 44, fat_g: 18,
                 items: [
                    FoodItem(foodId: nil, name: "Turkey sandwich", quantity: 1, unit: "sandwich", grams: 240,
                             kcal100g: 175, protein100g: 13, carbs100g: 18, fat100g: 6,
                             confidence: 1, isEstimate: false),
                    FoodItem(foodId: nil, name: "Side salad", quantity: 1, unit: "bowl", grams: 120,
                             kcal100g: 83, protein100g: 2, carbs100g: 4, fat100g: 6.5,
                             confidence: 1, isEstimate: false),
                 ], note: nil, aiConfidence: nil),
            Meal(id: "sample-3", slot: .dinner, calories: 385, protein_g: 27, carbs_g: 39, fat_g: 13,
                 items: [
                    FoodItem(foodId: nil, name: "Grilled chicken", quantity: 1, unit: "breast", grams: 130,
                             kcal100g: 165, protein100g: 31, carbs100g: 0, fat100g: 3.6,
                             confidence: 1, isEstimate: false),
                    FoodItem(foodId: nil, name: "Rice", quantity: 1, unit: "cup", grams: 150,
                             kcal100g: 130, protein100g: 2.7, carbs100g: 28, fat100g: 0.3,
                             confidence: 1, isEstimate: false),
                 ], note: nil, aiConfidence: nil),
        ]
    )

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
