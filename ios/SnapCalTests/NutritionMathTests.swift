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
