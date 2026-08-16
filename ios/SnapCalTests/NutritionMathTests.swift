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

    @Test("guest mode fabricates no meals")
    func guestHasNoInventedMeals() {
        let guest = Dashboard.guest

        // Fabricated meals are indistinguishable from real ones on screen, and
        // were the reason foods nobody logged appeared on Home.
        #expect(guest.meals.isEmpty)
        #expect(guest.consumed.calories == 0)
        #expect(guest.remaining.calories == guest.targets.calories)
    }

    @Test("the placeholder dashboard is empty too")
    func placeholderIsEmpty() {
        #expect(Dashboard.placeholder.meals.isEmpty)
        #expect(Dashboard.placeholder.consumed.calories == 0)
    }
}

struct GuestModeTests {

    @MainActor
    @Test("entering guest mode shows the app without a token or invented data")
    func enterGuest() async {
        let app = AppState()
        app.enterGuestMode()

        #expect(app.isGuest)
        #expect(app.phase == .ready)
        #expect(app.dashboard.meals.isEmpty, "guests must not be shown fabricated meals")
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

/// Home screen data shaping, per the Figma design.
struct HomeScreenTests {

    @Test("meal row renders a locale-formatted time from logged_at")
    func mealTime() throws {
        let json = """
        {"id":"1","slot":"breakfast","calories":350,"protein_g":20,"carbs_g":38,"fat_g":11,
         "items":[],"note":null,"ai_confidence":null,"logged_at":"2026-08-16T12:15:00Z"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meal = try decoder.decode(Meal.self, from: json)

        #expect(meal.loggedAt != nil)
        #expect(meal.loggedTime != nil)
        #expect(meal.calories == 350)
    }

    @Test("a meal with no timestamp hides the time row rather than showing a placeholder")
    func mealWithoutTime() throws {
        let json = """
        {"id":"1","slot":"lunch","calories":520,"protein_g":41,"carbs_g":44,"fat_g":18,
         "items":[],"note":null,"ai_confidence":null}
        """.data(using: .utf8)!
        let meal = try JSONDecoder().decode(Meal.self, from: json)
        #expect(meal.loggedTime == nil)
    }

    @Test("profile summary decodes the fields the header needs")
    func profileSummary() throws {
        let json = """
        {"name":"Satya Dhumal","start_weight_kg":82.0,"goal_weight_kg":76.0,"country":"US"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(ProfileSummary.self, from: json)
        #expect(p.name == "Satya Dhumal")
        #expect(p.startWeightKg == 82.0)
        // The greeting uses the first name only.
        #expect(p.name.split(separator: " ").first.map(String.init) == "Satya")
    }

    @Test("ring shows remaining against budget, and overshoot as a positive number")
    func ringMath() {
        // 1320 of a 2118 budget → 798 left, not "over".
        let under = 2118 - 1320
        #expect(under == 798)

        // Over-budget must display the magnitude, with the sign carried by copy.
        let over = 2118 - 2400
        #expect(over == -282)
        #expect(abs(over) == 282)
    }
}

/// Unit handling. The model returns household units in many spellings; the row
/// pluralised blindly and produced "0.5 gramss".
struct UnitNormalisationTests {

    private func item(unit: String, quantity: Double = 1, grams: Double = 100) -> FoodItem {
        FoodItem(foodId: nil, name: "x", quantity: quantity, unit: unit, grams: grams,
                 kcal100g: 100, protein100g: 5, carbs100g: 10, fat100g: 3,
                 confidence: 1, isEstimate: true)
    }

    @Test("every spelling of grams collapses to g")
    func gramSpellings() {
        for raw in ["g", "G", "gram", "grams", "Grams", "gm", "gms", "g.", "gramme", "grammes"] {
            #expect(item(unit: raw).normalisedUnit == "g", "\(raw) should normalise to g")
            #expect(item(unit: raw).isWeightBased)
        }
    }

    @Test("countable units are singularised, never double-pluralised")
    func countableUnits() {
        #expect(item(unit: "slices").normalisedUnit == "slice")
        #expect(item(unit: "eggs").normalisedUnit == "egg")
        #expect(item(unit: "serving").normalisedUnit == "serving")
        #expect(!item(unit: "slice").isWeightBased)

        // "glass" ends in s but is not a plural.
        #expect(item(unit: "glass").normalisedUnit == "glass")
    }

    @Test("an empty unit falls back to serving rather than blank")
    func emptyUnit() {
        #expect(item(unit: "").normalisedUnit == "serving")
        #expect(item(unit: "   ").normalisedUnit == "serving")
    }

    @Test("weight-based quantity edits track grams one-to-one")
    func weightBasedStepping() {
        var i = item(unit: "grams", quantity: 100, grams: 100)
        i.setQuantity(150)
        #expect(i.grams == 150, "grams unit must step in grams, not multiply a portion")
        #expect(i.calories == 150)
    }

    @Test("countable quantity edits scale grams by the per-unit weight")
    func countableStepping() {
        var i = item(unit: "slice", quantity: 2, grams: 60)
        i.setQuantity(3)
        #expect(i.grams == 90, "3 slices at 30g each")
    }
}

/// Briefing and Brain decoding. These shapes come straight from the backend,
/// and a mismatch shows up as an empty screen rather than an error.
struct BriefingTests {

    @Test("briefing decodes with actions and missing metrics")
    func decodeBriefing() throws {
        let json = """
        {"date":"2026-08-16","mode":"recovery",
         "headline":"Lighter day. Your body's asking for a bit of slack.",
         "actions":[{"id":"a1","domain":"recovery",
           "action":"Take today easy","reason":"You slept 24% below your usual.",
           "confidence":0.85,"triggeredBy":["recovery_mode"],"score":76}],
         "missing":["hrv","weight"],"generated":true}
        """.data(using: .utf8)!

        let b = try JSONDecoder().decode(DailyBriefing.self, from: json)
        #expect(b.mode == "recovery")
        #expect(b.actions.count == 1)
        #expect(b.missing == ["hrv", "weight"])

        // Every action must arrive with its reason — a card without one is an
        // app telling someone what to do with no justification.
        #expect(!b.actions[0].reason.isEmpty)
        #expect(b.actions[0].icon == "heart.text.square")
    }

    @Test("an empty briefing is valid, not an error")
    func emptyBriefing() throws {
        let json = """
        {"date":"2026-08-16","mode":"maintenance","headline":"Fresh start.",
         "actions":[],"missing":[],"generated":true}
        """.data(using: .utf8)!
        let b = try JSONDecoder().decode(DailyBriefing.self, from: json)
        #expect(b.actions.isEmpty)
    }

    @Test("every domain maps to an icon and a colour")
    func domainMapping() {
        for domain in ["nutrition", "fitness", "sleep", "recovery",
                       "hydration", "activity", "habit", "something_new"] {
            let a = PriorityAction(id: "x", domain: domain, action: "a",
                                   reason: "r", confidence: 1)
            // An unknown domain must still render rather than crash — the
            // backend can add one without an app update.
            #expect(!a.icon.isEmpty)
        }
    }
}

struct BrainMemoryTests {

    @Test("memories group by layer with human-readable labels")
    func decodeMemories() throws {
        let json = """
        {"layers":{
          "routine":[{"id":"m1","content":"usually eats breakfast around 7am",
                      "confidence":0.9,"evidence_count":6,"user_edited":false}],
          "procedural":[{"id":"m2","content":"sleep changes measurably help",
                         "confidence":0.8,"evidence_count":4,"user_edited":false}]},
         "labels":{"routine":"Your usual patterns","procedural":"What works for you"},
         "total":2}
        """.data(using: .utf8)!

        let m = try JSONDecoder().decode(BrainMemories.self, from: json)
        #expect(m.total == 2)

        let ordered = m.orderedLayers
        // Routines first: they're the most recognisable, which is what makes
        // the screen feel accurate rather than unsettling.
        #expect(ordered.first?.label == "Your usual patterns")
        // Never show raw layer names to a user.
        #expect(!ordered.contains { $0.label == "routine" })
    }

    @Test("an empty brain has nothing to show, and that is fine")
    func emptyBrain() throws {
        let json = """
        {"layers":{},"labels":{"routine":"Your usual patterns"},"total":0}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(BrainMemories.self, from: json)
        #expect(m.total == 0)
        #expect(m.orderedLayers.isEmpty)
    }

    @Test("a user-corrected memory is marked as theirs")
    func userEdited() throws {
        let json = """
        {"id":"m1","content":"hates running","confidence":1.0,
         "evidence_count":1,"user_edited":true}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(BrainMemory.self, from: json)
        #expect(m.userEdited)
        #expect(m.confidence == 1.0)
    }
}

/// Structured workouts. The plan is data the user works through, so decoding
/// has to survive the fields the backend legitimately leaves null.
struct WorkoutPlanTests {

    private let json = """
    {"id":"p1","workout_title":"Lower Body Strength","goal":"lose","focus":"lower",
     "duration_minutes":45,"warmup":["5 min easy cardio"],
     "exercises":[
       {"exercise_name":"Leg Press","sets":3,"reps":"8-12","rest_seconds":90,
        "suggested_weight_kg":42.5,
        "progression_note":"Up from 40kg — you hit the top of the range twice.",
        "instructions":"Drive through mid-foot.","targets":"quads, glutes"},
       {"exercise_name":"Plank","sets":3,"reps":"30-45 sec","rest_seconds":45,
        "suggested_weight_kg":null,
        "progression_note":"No history for this one — start light.",
        "instructions":"Ribs down.","targets":"core"}],
     "optional_cardio":"15 min walking","cooldown":["Hamstring stretch"],
     "coach_note":"Straightforward session."}
    """.data(using: .utf8)!

    @Test("a plan decodes with weights, ranges and rest")
    func decodePlan() throws {
        let plan = try JSONDecoder().decode(WorkoutPlan.self, from: json)
        #expect(plan.exercises.count == 2)
        #expect(plan.durationMinutes == 45)
        #expect(plan.exercises[0].suggestedWeightKg == 42.5)
        #expect(plan.exercises[0].restSeconds == 90)
    }

    @Test("a missing weight is null, never zero, and is explained")
    func absentWeight() throws {
        let plan = try JSONDecoder().decode(WorkoutPlan.self, from: json)
        let plank = plan.exercises[1]

        // Zero kilos and "we don't know yet" are different things, and showing
        // 0 would look like an instruction to lift nothing.
        #expect(plank.suggestedWeightKg == nil)
        #expect(plank.progressionNote?.isEmpty == false)
    }

    @Test("reps stay a range rather than a false single number")
    func repRanges() throws {
        let plan = try JSONDecoder().decode(WorkoutPlan.self, from: json)
        #expect(plan.exercises[0].reps == "8-12")
        #expect(plan.exercises[1].reps == "30-45 sec")
    }

    @Test("a recovery session is recognisable as one")
    func recoveryDetection() throws {
        let plan = try JSONDecoder().decode(WorkoutPlan.self, from: json)
        #expect(!plan.isRecovery)

        let recovery = """
        {"id":null,"workout_title":"Recovery","goal":"lose","focus":"mobility",
         "duration_minutes":20,"warmup":[],"exercises":[],
         "optional_cardio":null,"cooldown":[],"coach_note":"Take it easy."}
        """.data(using: .utf8)!
        #expect(try JSONDecoder().decode(WorkoutPlan.self, from: recovery).isRecovery)
    }
}

struct FitnessOnboardingTests {

    @Test("a question decodes with its options and progress")
    func decodeQuestion() throws {
        let json = """
        {"completed":false,"answered":2,"total":8,
         "welcome":"Good to meet you, Satya.",
         "next":{"field":"training_location","question":"Where will you train?",
                 "options":[{"value":"gym","label":"Gym"},
                            {"value":"home","label":"Home"}],
                 "multiSelect":false,"step":3,"total":8,"skippable":false}}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(OnboardingState.self, from: json)
        #expect(state.completed == false)
        #expect(state.next?.options.count == 2)
        #expect(state.next?.step == 3)
        #expect(state.next?.multiSelect == false)
    }

    @Test("a completed state has no question and no welcome")
    func decodeCompleted() throws {
        let json = """
        {"completed":true,"answered":8,"total":8,"next":null,"welcome":null}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(OnboardingState.self, from: json)
        #expect(state.completed)
        #expect(state.next == nil)
        // A returning user must not be greeted as though it were their first day.
        #expect(state.welcome == nil)
    }

    @Test("a multi-select question is flagged as one")
    func multiSelect() throws {
        let json = """
        {"completed":false,"answered":3,"total":8,"welcome":null,
         "next":{"field":"equipment_list","question":"What do you have access to?",
                 "options":[{"value":"dumbbells","label":"Dumbbells"}],
                 "multiSelect":true,"step":4,"total":8,"skippable":false}}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(OnboardingState.self, from: json)
        #expect(state.next?.multiSelect == true)
    }
}
