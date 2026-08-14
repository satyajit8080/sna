import Testing
import Foundation
@testable import SnapCal

/// These cover the arithmetic the app does locally instead of calling the AI.
/// If this drifts, users see different numbers before and after a portion edit.
struct NutritionMathTests {

    private func roti(quantity: Double = 2) -> FoodItem {
        FoodItem(foodId: nil, name: "roti", quantity: quantity, unit: "roti",
                 grams: 45 * quantity, kcal100g: 264, protein100g: 9,
                 carbs100g: 49, fat100g: 3.7, confidence: 0.9, isEstimate: true)
    }

    @Test("macros derive from grams and per-100g values")
    func macrosDerive() {
        let item = roti()
        #expect(item.calories == 238)   // 90g * 264/100 = 237.6
        #expect(item.protein == 8)
        #expect(item.carbs == 44)
        #expect(item.fat == 3)
    }

    @Test("changing quantity rescales grams and macros without a network call")
    func quantityRescales() {
        var item = roti()
        item.setQuantity(4)
        #expect(item.grams == 180)
        #expect(item.calories == 475)
    }

    @Test("quantity is floored so a meal can never reach zero grams")
    func quantityFloor() {
        var item = roti()
        item.setQuantity(0)
        #expect(item.quantity == 0.25)
        #expect(item.grams > 0)
    }

    @Test("gram-unit items track quantity one-to-one")
    func gramUnit() {
        var item = FoodItem(foodId: nil, name: "chicken breast", quantity: 150, unit: "g",
                            grams: 150, kcal100g: 165, protein100g: 31, carbs100g: 0,
                            fat100g: 3.6, confidence: 1, isEstimate: false)
        #expect(item.calories == 248)
        item.setQuantity(300)
        #expect(item.grams == 300)
        #expect(item.calories == 495)
    }

    @Test("meal slot follows time of day")
    func slotSuggestion() {
        func at(_ hour: Int) -> Date {
            Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
        }
        #expect(MealSlot.suggested(at: at(8)) == .breakfast)
        #expect(MealSlot.suggested(at: at(13)) == .lunch)
        #expect(MealSlot.suggested(at: at(20)) == .dinner)
        #expect(MealSlot.suggested(at: at(2)) == .snack)
    }
}

struct APIConfigurationTests {

    /// Guards the single most likely TestFlight failure: shipping a build that
    /// still points at localhost.
    @Test("release builds use an HTTPS API base URL")
    func releaseUsesHTTPS() throws {
        let raw = try #require(Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String)
        let url = try #require(URL(string: raw))
        #expect(url.host != nil)
        #expect(raw.hasSuffix("/api/v1"))

        #if !DEBUG
        #expect(url.scheme == "https", "Release build must not use plaintext HTTP")
        #expect(url.host != "localhost")
        #endif
    }

    @Test("no provider secrets are embedded in the bundle")
    func noEmbeddedSecrets() {
        let info = Bundle.main.infoDictionary ?? [:]
        for key in ["OPENAI_API_KEY", "GEMINI_API_KEY", "JWT_SECRET", "DATABASE_URL"] {
            #expect(info[key] == nil, "\(key) must never ship in the app")
        }
    }
}

struct DecodingTests {

    @Test("analysis response decodes the server envelope")
    func decodeAnalysis() throws {
        let json = """
        {"foods":[{"food_id":null,"name":"dal tadka","quantity":1,"unit":"katori","grams":150,
        "kcal_100g":118,"protein_100g":6,"carbs_100g":15,"fat_100g":3.6,"confidence":0.84,
        "is_estimate":true,"matched_source":"curated","calories":177,"protein_g":9,
        "carbs_g":23,"fat_g":5}],"total":{"calories":177,"protein_g":9,"carbs_g":23,"fat_g":5},
        "confidence":0.84,"assumptions":["Assumed 1 tsp oil"],"is_estimate":true,
        "disclaimer":"AI estimate. Not a medical or clinical measurement."}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AnalysisResponse.self, from: json)
        #expect(decoded.foods.count == 1)
        #expect(decoded.total.calories == 177)
        #expect(decoded.isEstimate)
        #expect(decoded.foods[0].calories == 177)
    }
}

/// Entitlement rendering. The client must never invent limits — these assert
/// that badge copy is derived purely from what the backend reported.
struct EntitlementTests {

    private func usage(_ used: Int, _ limit: Int?, premiumOnly: Bool = false) -> FeatureUsage {
        FeatureUsage(feature: "food_scan", used: used, limit: limit,
                     remaining: limit.map { max(0, $0 - used) }, premiumOnly: premiumOnly)
    }

    @Test("badge copy matches the spec at each step of the free allowance")
    func badgeCopy() {
        #expect(usage(0, 2).badge(noun: "AI scan") == "2 free AI scans available")
        #expect(usage(1, 2).badge(noun: "AI scan") == "1 free AI scan remaining")
        #expect(usage(2, 2).badge(noun: "AI scan") == "No AI scans left")
    }

    @Test("premium-only features never show a count")
    func premiumOnlyBadge() {
        #expect(usage(0, 0, premiumOnly: true).badge(noun: "plan") == "Premium Feature")
    }

    @Test("unlimited never renders a number")
    func unlimitedBadge() {
        let pro = usage(500, nil)
        #expect(pro.isUnlimited)
        #expect(pro.badge(noun: "AI scan") == "Unlimited")
        #expect(!pro.isExhausted)
    }

    @Test("exhaustion is driven by remaining, not by used")
    func exhaustion() {
        #expect(!usage(1, 2).isExhausted)
        #expect(usage(2, 2).isExhausted)
        #expect(usage(0, 0, premiumOnly: true).isExhausted)
    }

    @Test("PREMIUM_REQUIRED routes to the paywall for the blocked feature")
    func paywallRouting() {
        #expect(PremiumRequired(feature: "coach", reason: "limit_reached", usage: nil).context == .coach)
        #expect(PremiumRequired(feature: "meal_plan", reason: "premium_only", usage: nil).context == .mealPlan)
        #expect(PremiumRequired(feature: "food_scan", reason: "limit_reached", usage: nil).context == .foodScan)
        // An unknown feature must still produce a usable paywall.
        #expect(PremiumRequired(feature: "something_new", reason: "limit_reached", usage: nil).context == .foodScan)
    }

    @Test("every paywall context has copy and benefits")
    func paywallCopy() {
        for context in [PaywallContext.foodScan, .coach, .mealPlan, .report, .general] {
            #expect(!context.headline.isEmpty)
            #expect(!context.subhead.isEmpty)
            #expect(context.benefits.count >= 4)
        }
    }

    @Test("entitlements decode the backend payload")
    func decodeEntitlements() throws {
        let json = """
        {"plan":"free","periodStart":"2026-08-01T00:00:00Z","periodEnd":"2026-08-31T00:00:00Z",
         "features":{
           "food_scan":{"feature":"food_scan","used":1,"limit":2,"remaining":1,"premiumOnly":false},
           "coach":{"feature":"coach","used":0,"limit":2,"remaining":2,"premiumOnly":false},
           "meal_plan":{"feature":"meal_plan","used":0,"limit":0,"remaining":0,"premiumOnly":true}}}
        """.data(using: .utf8)!

        let e = try JSONDecoder().decode(Entitlements.self, from: json)
        #expect(!e.isPro)
        #expect(e.foodScan.remaining == 1)
        #expect(e.mealPlan.premiumOnly)
        #expect(e.coach.limit == 2)
    }

    @Test("pro entitlements report unlimited, not a large number")
    func decodeProEntitlements() throws {
        let json = """
        {"plan":"pro","periodStart":"","periodEnd":"",
         "features":{"coach":{"feature":"coach","used":40,"limit":null,"remaining":null,"premiumOnly":false}}}
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(Entitlements.self, from: json)
        #expect(e.isPro)
        #expect(e.coach.isUnlimited)
    }
}

struct MealPlanTests {

    @Test("a planned meal converts to a diary item with matching macros")
    func plannedMealConversion() {
        let planned = PlannedMeal(slot: "lunch", name: "Dal tadka", grams: 150,
                                  kcal: 177, protein_g: 9, carbs_g: 23, fat_g: 5)
        let item = planned.asFoodItem

        #expect(item.grams == 150)
        // Round-trips through per-100g without drifting.
        #expect(item.calories == 177)
        #expect(item.protein == 9)
        #expect(item.carbs == 23)
    }

    @Test("day totals sum the meals")
    func dayTotals() {
        let day = PlanDay(date: "2026-08-14", meals: [
            PlannedMeal(slot: "breakfast", name: "Poha", grams: 180, kcal: 279, protein_g: 5, carbs_g: 47, fat_g: 8),
            PlannedMeal(slot: "lunch", name: "Roti", grams: 90, kcal: 238, protein_g: 8, carbs_g: 44, fat_g: 3),
        ])
        #expect(day.totalKcal == 517)
        #expect(day.totalProtein == 13)
    }

    @Test("meal plan decodes the backend envelope")
    func decodePlan() throws {
        let json = """
        {"days":[{"date":"2026-08-14","meals":[
          {"slot":"breakfast","name":"Poha","grams":180,"kcal":279,"protein_g":5,"carbs_g":47,"fat_g":8}]}],
         "note":"Balanced around your protein target."}
        """.data(using: .utf8)!
        let plan = try JSONDecoder().decode(MealPlan.self, from: json)
        #expect(plan.days.count == 1)
        #expect(plan.days[0].meals[0].name == "Poha")
        #expect(plan.note != nil)
    }
}

struct NotificationPrefsTests {

    @Test("defaults match the spec: daily coach on at 8am, offers on")
    func defaults() {
        let p = NotificationPrefs.default
        #expect(p.dailyCoach)
        #expect(p.morningHour == 8)
        #expect(p.morningMinute == 0)
        #expect(p.premiumOffers)
        #expect(p.permission == "undetermined")
    }

    @Test("prefs round-trip through the backend's snake_case keys")
    func decoding() throws {
        let json = """
        {"daily_coach":false,"morning_hour":7,"morning_minute":30,"meal_reminders":true,
         "food_logging":false,"coach_reminder":true,"premium_offers":false,"permission":"granted"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(NotificationPrefs.self, from: json)
        #expect(!p.dailyCoach)
        #expect(p.morningHour == 7)
        #expect(p.morningMinute == 30)
        #expect(!p.premiumOffers)

        let re = try JSONDecoder().decode(NotificationPrefs.self, from: JSONEncoder().encode(p))
        #expect(re == p)
    }
}
