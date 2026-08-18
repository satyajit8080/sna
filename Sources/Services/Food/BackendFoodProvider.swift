import Foundation

private struct FoodSearchResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let brand: String?
        let sodiumMilligramsPer100g: Double
        let energyKilocaloriesPer100g: Double?
        let defaultServingGrams: Double?
        let source: String
    }

    let items: [Item]
    let attribution: String
}

private struct FoodDetailResponse: Decodable {
    let item: FoodSearchResponse.Item
    let attribution: String
}

/// Food and sodium lookup through the BP Coach backend, which proxies USDA
/// FoodData Central.
///
/// USDA is public domain, unlike Open Food Facts, whose ODbL share-alike terms
/// would attach obligations to anything derived from it. The USDA key stays on
/// the server.
struct BackendFoodProvider: FoodDataProvider {

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    let displayName = "USDA FoodData Central"
    var isAvailable: Bool { true }

    func search(_ query: String, limit: Int) async throws -> [FoodItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/food/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { return [] }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return [] }

        // A 503 means the provider is not configured. Returning an empty list
        // rather than throwing keeps manual entry working, which is the whole
        // point of the abstraction.
        guard http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(FoodSearchResponse.self, from: data)
        return decoded.items.map(Self.map)
    }

    func item(withID id: String) async throws -> FoodItem? {
        let url = baseURL.appendingPathComponent("v1/food/\(id)")
        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return Self.map(try JSONDecoder().decode(FoodDetailResponse.self, from: data).item)
    }

    /// Values from a nutrition database are lookups, not estimates. That
    /// distinction drives whether the UI shows the "Estimate" tag, so it is set
    /// here rather than inferred later.
    private static func map(_ item: FoodSearchResponse.Item) -> FoodItem {
        FoodItem(
            id: item.id,
            name: item.name,
            brand: item.brand,
            sodiumMilligramsPer100g: item.sodiumMilligramsPer100g,
            energyKilocaloriesPer100g: item.energyKilocaloriesPer100g,
            defaultServingGrams: item.defaultServingGrams,
            source: item.source,
            provenance: .databaseLookup
        )
    }
}

/// Portion maths for a looked-up food.
enum FoodPortion {
    /// Sodium for a given weight. Database values are per 100 g, and shipping
    /// a per-100g figure as if it were per-serving is the obvious way to be
    /// badly wrong in a sodium tracker.
    static func sodiumMilligrams(for item: FoodItem, grams: Double) -> Double {
        (item.sodiumMilligramsPer100g / 100.0) * grams
    }

    static func calories(for item: FoodItem, grams: Double) -> Double? {
        guard let per100 = item.energyKilocaloriesPer100g else { return nil }
        return (per100 / 100.0) * grams
    }

    /// Falls back to 100 g when the record has no serving size, so the UI always
    /// has a defensible starting number.
    static func defaultGrams(for item: FoodItem) -> Double {
        item.defaultServingGrams ?? 100
    }
}
