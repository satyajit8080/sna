import Foundation

/// A food item with the nutrition fields BP Coach actually cares about.
///
/// Sodium is the point. Any provider that cannot supply sodium is not useful
/// here, which is why it is non-optional per 100g.
struct FoodItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let brand: String?
    /// Milligrams per 100 grams.
    let sodiumMilligramsPer100g: Double
    let energyKilocaloriesPer100g: Double?
    let defaultServingGrams: Double?
    let source: String
    let provenance: ValueProvenance
}

/// Abstraction over a future food and sodium data source.
///
/// The SnapCal audit established that no reusable sodium dataset exists: SnapCal
/// stores no sodium column and resolves nutrition server-side at request time.
/// BP Coach therefore needs its own provider, and this protocol exists so that
/// choosing one later is a single conformance rather than a rewrite.
///
/// Candidate implementations: a bundled curated dataset, USDA FoodData Central,
/// Open Food Facts (ODbL — attribution and share-alike apply), or manual entry.
protocol FoodDataProvider: Sendable {
    var displayName: String { get }
    var isAvailable: Bool { get }

    func search(_ query: String, limit: Int) async throws -> [FoodItem]
    /// Looks a barcode up directly. Separate from `search` because barcode
    /// lookup uses a different, global database — searching for the digits as
    /// text finds nothing.
    func lookup(barcode: String) async throws -> FoodItem?
    func item(withID id: String) async throws -> FoodItem?
}

/// The provider in use until a real data source is selected.
///
/// It returns nothing rather than inventing plausible values. An empty result is
/// honest; a fabricated sodium figure in a blood pressure app is not.
struct UnconfiguredFoodDataProvider: FoodDataProvider {
    let displayName = "Not configured"
    let isAvailable = false

    func search(_ query: String, limit: Int) async throws -> [FoodItem] { [] }
    func lookup(barcode: String) async throws -> FoodItem? { nil }
    func item(withID id: String) async throws -> FoodItem? { nil }
}

/// Manual sodium entry. Always available, because a user who reads a label can
/// always record what it says.
struct ManualSodiumEntry {
    /// Daily sodium reference points, for context in the UI.
    static let ahaIdealDailyMilligrams = 1_500
    static let ahaUpperDailyMilligrams = 2_300

    static func dailyTotal(_ entries: [LifestyleEntry]) -> (total: Double, containsEstimate: Bool) {
        let sodium = entries.filter { $0.kind == .sodium }
        return (
            sodium.reduce(0) { $0 + $1.value },
            sodium.contains(where: \.isEstimate)
        )
    }
}
