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

/// First-run localisation. The food database handles every cuisine; these
/// assert that the *visible* first-run examples are North American, so a
/// cold-start user in Ohio recognises the first plate they see.
struct LocalizationTests {

    private static let indiaSpecific = [
        "roti", "chapati", "dal", "paneer", "poha", "idli", "dosa",
        "sabzi", "bhindi", "thali", "katori", "samosa", "biryani",
    ]

    @Test("guest sample day uses North American foods only")
    func guestSampleIsNorthAmerican() {
        let names = Dashboard.guestSample.meals
            .flatMap(\.items)
            .map { $0.name.lowercased() }

        #expect(!names.isEmpty)
        for term in Self.indiaSpecific {
            #expect(!names.contains { $0.contains(term) },
                    "guest sample must not surface '\(term)' on first run")
        }
        #expect(names.contains { $0.contains("chicken") || $0.contains("eggs") || $0.contains("sandwich") })
    }

    @Test("guest sample is a realistic part-eaten day, not an empty shell")
    func guestSampleIsPopulated() {
        let sample = Dashboard.guestSample
        #expect(sample.meals.count >= 3)
        #expect(sample.consumed.calories > 0)
        #expect(sample.remaining.calories > 0, "should still have room left")
        #expect(sample.consumed.calories + sample.remaining.calories == sample.targets.calories)
    }
}

struct GuestModeTests {

    @MainActor
    @Test("entering guest mode shows the app without a token")
    func enterGuest() async {
        let app = AppState()
        app.enterGuestMode()

        #expect(app.isGuest)
        #expect(app.phase == .ready)
        #expect(app.dashboard.meals.count >= 3, "guests see sample content, not an empty app")
    }

    @MainActor
    @Test("guest actions requiring a server raise the sign-up prompt")
    func guestGating() async {
        let app = AppState()
        app.enterGuestMode()

        #expect(app.requireAccount(for: "save your meals") == false)
        #expect(app.guestPromptFeature == "save your meals")
    }

    @MainActor
    @Test("an authenticated user is never gated")
    func authenticatedNotGated() async {
        let app = AppState()
        #expect(app.isGuest == false)
        #expect(app.requireAccount(for: "save your meals") == true)
        #expect(app.guestPromptFeature == nil)
    }

    @MainActor
    @Test("leaving guest mode clears the prompt")
    func leaveGuest() async {
        let app = AppState()
        app.enterGuestMode()
        _ = app.requireAccount(for: "ask your coach")
        app.leaveGuestMode()

        #expect(app.isGuest == false)
        #expect(app.guestPromptFeature == nil)
    }

    @MainActor
    @Test("signing out returns to the welcome screen and clears guest state")
    func signOutResets() async {
        let app = AppState()
        app.enterGuestMode()
        await app.signOut()

        #expect(app.isGuest == false)
        #expect(app.phase == .welcome)
    }
}

/// The connected loop: scan → activity → coach → plan → log → dashboard.
struct LoopTests {

    @Test("dashboard ring tracks the activity-adjusted budget, not the base target")
    func ringUsesBudget() throws {
        let json = """
        {"date":"2026-08-15","timezone":"America/New_York","resets_at":"2026-08-16T04:00:00Z",
         "targets":{"calories":2000,"protein_g":150,"carbs_g":220,"fat_g":60,"water_ml":2500},
         "consumed":{"calories":800,"protein_g":60,"carbs_g":80,"fat_g":25},
         "activity":{"steps":12000,"active_kcal":500,"credited_kcal":250,
                     "exercise_min":40,"kcal_source":"healthkit"},
         "budget":{"base_calories":2000,"activity_bonus":250,"total_calories":2250},
         "remaining":{"calories":1450,"protein_g":90,"carbs_g":140,"fat_g":35},
         "water_ml":1000,"current_weight_kg":80.0,"streak_days":3,"meals":[]}
        """.data(using: .utf8)!

        let d = try JSONDecoder().decode(Dashboard.self, from: json)
        #expect(d.budgetCalories == 2250, "ring must use the adjusted budget")
        #expect(d.activityBonus == 250)
        #expect(d.activity?.steps == 12000)
        // Remaining is budget minus consumed, not target minus consumed.
        #expect(d.remaining.calories == d.budgetCalories - d.consumed.calories)
    }

    @Test("an older server response without activity still decodes")
    func backwardCompatible() throws {
        let json = """
        {"date":"2026-08-15",
         "targets":{"calories":2000,"protein_g":150,"carbs_g":220,"fat_g":60,"water_ml":2500},
         "consumed":{"calories":800,"protein_g":60,"carbs_g":80,"fat_g":25},
         "remaining":{"calories":1200,"protein_g":90,"carbs_g":140,"fat_g":35},
         "water_ml":1000,"current_weight_kg":80.0,"streak_days":3,"meals":[]}
        """.data(using: .utf8)!

        let d = try JSONDecoder().decode(Dashboard.self, from: json)
        #expect(d.budgetCalories == 2000, "falls back to the plain target")
        #expect(d.activityBonus == 0)
    }

    @Test("a coach suggestion converts to a diary item with identical macros")
    func suggestionRoundTrip() throws {
        let json = """
        {"food_id":"abc","name":"grilled chicken breast","slot":"dinner",
         "grams":150,"quantity":1,"unit":"serving",
         "kcal_100g":165,"protein_100g":31,"carbs_100g":0,"fat_100g":3.6,
         "calories":248,"protein_g":47,"carbs_g":0,"fat_g":5,
         "reason":"47g protein, fits your 900 kcal left"}
        """.data(using: .utf8)!

        let s = try JSONDecoder().decode(MealSuggestion.self, from: json)
        let item = s.asFoodItem

        // What the card shows must equal what the diary saves.
        #expect(item.calories == s.calories)
        #expect(item.protein == s.protein_g)
        #expect(item.grams == s.grams)
        #expect(item.isEstimate == false, "database macros are exact, not estimates")
        #expect(item.foodId == "abc")
    }

    @Test("coach answer decodes with and without a suggestion")
    func coachAnswerDecoding() throws {
        let withSuggestion = """
        {"answer":"Yes — you have 900 left, chicken is 248.",
         "suggestion":{"food_id":"abc","name":"chicken","slot":"dinner","grams":150,
           "quantity":1,"unit":"serving","kcal_100g":165,"protein_100g":31,
           "carbs_100g":0,"fat_100g":3.6,"calories":248,"protein_g":47,
           "carbs_g":0,"fat_g":5,"reason":"fits"},
         "entitlements":{"plan":"pro","periodStart":"","periodEnd":"","features":{}}}
        """.data(using: .utf8)!

        let a = try JSONDecoder().decode(CoachAnswer.self, from: withSuggestion)
        #expect(a.suggestion != nil)
        #expect(a.answer.split(separator: "\n").count == 1, "coach stays one line")

        let without = """
        {"answer":"You're done for today.","suggestion":null,
         "entitlements":{"plan":"free","periodStart":"","periodEnd":"","features":{}}}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(CoachAnswer.self, from: without).suggestion == nil)
    }

    @Test("meal plan reports whether it covers the rest of today")
    func planScope() throws {
        let restOfDay = """
        {"days":[],"note":"n","planned_for":"remaining_today","budget_kcal":900}
        """.data(using: .utf8)!
        let plan = try JSONDecoder().decode(MealPlan.self, from: restOfDay)
        #expect(plan.isRestOfDay)
        #expect(plan.budgetKcal == 900)

        let fullDay = """
        {"days":[],"note":"n","planned_for":"full_day","budget_kcal":2000}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(MealPlan.self, from: fullDay).isRestOfDay == false)
    }
}
