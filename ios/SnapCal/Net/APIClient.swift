import Foundation
import UIKit

enum APIError: LocalizedError, Equatable {
    case unauthorized
    case scanLimitReached(used: Int, limit: Int)
    case proRequired(feature: String)
    case noFoodDetected
    case offline
    case timeout
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:        "Please sign in again."
        case .scanLimitReached:    "You've used your free scans this week."
        case .proRequired:         "This is a Pro feature."
        case .noFoodDetected:      "We couldn't find food in that photo."
        case .offline:             "You're offline. We'll retry when you're back."
        case .timeout:             "That took too long. Try again."
        case .server(let m):       m
        }
    }

    /// Errors the user can recover from with one tap.
    var isRetryable: Bool {
        switch self { case .offline, .timeout, .server: true; default: false }
    }
}

private struct ErrorBody: Decodable {
    let error: String
    let message: String?
    let feature: String?
    let quota: Quota?
}

actor APIClient {
    static let shared = APIClient()

    /// Injected from Debug.xcconfig / Release.xcconfig via Info.plist.
    /// No API URL is hardcoded in Swift, so a Railway domain change is a config
    /// edit rather than a code change.
    private let base: URL = {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
            let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
            url.scheme != nil, url.host != nil
        else {
            // A build that reaches here is misconfigured; fail loudly in debug
            // rather than silently pointing at nothing in TestFlight.
            assertionFailure("API_BASE_URL missing or malformed in Info.plist")
            return URL(string: "https://api.snapcal.app/api/v1")!
        }
        return url
    }()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let encoder = JSONEncoder()

    var token: String? {
        get { Keychain.get("auth_token") }
    }

    func setToken(_ value: String?) { Keychain.set(value, for: "auth_token") }

    // MARK: - Core request

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         contentType: String? = "application/json") -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.httpBody = body
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        return r
    }

    private func send<T: Decodable>(_ r: URLRequest, as: T.Type) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: r)
        } catch let e as URLError {
            throw e.code == .timedOut ? APIError.timeout : APIError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.server("Bad response") }

        if (200..<300).contains(http.statusCode) {
            if T.self == Empty.self { return Empty() as! T }
            return try decoder.decode(T.self, from: data)
        }

        let body = try? decoder.decode(ErrorBody.self, from: data)
        switch (http.statusCode, body?.error) {
        case (401, _):                        throw APIError.unauthorized
        case (402, "pro_required"):           throw APIError.proRequired(feature: body?.feature ?? "pro")
        case (402, _):                        throw APIError.scanLimitReached(used: body?.quota?.used ?? 0,
                                                                              limit: body?.quota?.limit ?? 2)
        case (422, "no_food_detected"):       throw APIError.noFoodDetected
        default:                              throw APIError.server(body?.message ?? "Something went wrong.")
        }
    }

    struct Empty: Codable {}

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try await send(request(path), as: T.self)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, _ body: B, as: T.Type) async throws -> T {
        try await send(request(path, method: "POST", body: try encoder.encode(body)), as: T.self)
    }

    // MARK: - Auth

    struct AuthResponse: Codable { let token: String; let onboarded: Bool }

    func signInWithApple(identityToken: String, name: String?) async throws -> AuthResponse {
        struct Body: Encodable { let identity_token: String; let name: String? }
        let res = try await post("auth/apple", Body(identity_token: identityToken, name: name), as: AuthResponse.self)
        setToken(res.token)
        return res
    }

    func submitProfile(_ p: ProfileDraft) async throws -> TargetsResponse {
        try await post("profile", p, as: TargetsResponse.self)
    }

    func deleteAccount() async throws {
        _ = try await send(request("account", method: "DELETE"), as: Empty.self)
        setToken(nil)
    }

    // MARK: - The scan path

    /// Image is downscaled and compressed **before** it leaves the device.
    /// 512px / q0.6 lands around 40-60 KB and ~330 image tokens.
    nonisolated func compress(_ image: UIImage, maxEdge: CGFloat = 512) -> Data? {
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let f = UIGraphicsImageRendererFormat.default(); f.scale = 1; f.opaque = true; return f
        }())
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.6)
    }

    func analyze(image: UIImage, hint: String? = nil) async throws -> AnalysisResponse {
        guard let jpeg = compress(image) else { throw APIError.server("Couldn't read that photo.") }

        let boundary = "snapcal.\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image\"; filename=\"m.jpg\"\r\n")
        append("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        append("\r\n")
        if let hint {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"hint\"\r\n\r\n\(hint)\r\n")
        }
        append("--\(boundary)--\r\n")

        let r = request("food/analyze", method: "POST", body: body,
                        contentType: "multipart/form-data; boundary=\(boundary)")
        return try await send(r, as: AnalysisResponse.self)
    }

    func analyze(text: String) async throws -> AnalysisResponse {
        struct Body: Encodable { let text: String }
        return try await post("food/text", Body(text: text), as: AnalysisResponse.self)
    }

    func analyze(transcript: String) async throws -> AnalysisResponse {
        struct Body: Encodable { let transcript: String }
        return try await post("food/voice", Body(transcript: transcript), as: AnalysisResponse.self)
    }

    func lookup(barcode: String) async throws -> AnalysisResponse {
        struct Body: Encodable { let barcode: String }
        return try await post("food/barcode", Body(barcode: barcode), as: AnalysisResponse.self)
    }

    func searchFoods(_ term: String) async throws -> [FoodItem] {
        struct Wrapper: Decodable { let results: [SearchRow] }
        struct SearchRow: Decodable {
            let id: String; let name: String; let brand: String?
            let kcal_100g: Double; let protein_100g: Double
            let carbs_100g: Double; let fat_100g: Double
            let default_unit: String?; let default_grams: Double?
        }
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let w = try await get("food/search?term=\(encoded)", as: Wrapper.self)
        // Named parameter, not $0: the inner closure that prefixes the brand
        // would otherwise shadow the outer one's shorthand argument.
        return w.results.map { row in
            let displayName = row.brand.map { "\($0) \(row.name)" } ?? row.name
            return FoodItem(foodId: row.id, name: displayName,
                            quantity: 1,
                            unit: row.default_unit ?? "g",
                            grams: row.default_grams ?? 100,
                            kcal100g: row.kcal_100g, protein100g: row.protein_100g,
                            carbs100g: row.carbs_100g, fat100g: row.fat_100g,
                            confidence: 1, isEstimate: false)
        }
    }

    // MARK: - Logging

    struct SaveMealBody: Encodable {
        let slot: String
        let input_method: String
        let note: String?
        let ai_confidence: Double?
        let items: [FoodItem]
    }

    struct SaveMealResponse: Codable { let id: String }

    func saveMeal(slot: MealSlot, method: String, items: [FoodItem],
                  confidence: Double?, note: String? = nil) async throws -> SaveMealResponse {
        try await post("meals",
                       SaveMealBody(slot: slot.rawValue, input_method: method,
                                    note: note, ai_confidence: confidence, items: items),
                       as: SaveMealResponse.self)
    }

    func updateMeal(id: String, items: [FoodItem], slot: MealSlot?) async throws {
        struct Body: Encodable { let slot: String?; let items: [FoodItem] }
        _ = try await send(request("meals/\(id)", method: "PATCH",
                                   body: try encoder.encode(Body(slot: slot?.rawValue, items: items))),
                           as: Empty.self)
    }

    func deleteMeal(id: String) async throws {
        _ = try await send(request("meals/\(id)", method: "DELETE"), as: Empty.self)
    }

    // MARK: - Reads

    func dashboard() async throws -> Dashboard { try await get("dashboard", as: Dashboard.self) }
    func usage() async throws -> Quota { try await get("usage", as: Quota.self) }
    func subscription() async throws -> SubscriptionStatus { try await get("subscription", as: SubscriptionStatus.self) }
    func history(range: String) async throws -> History { try await get("history?range=\(range)", as: History.self) }
    func weight(days: Int = 90) async throws -> WeightSeries { try await get("weight?days=\(days)", as: WeightSeries.self) }

    func logWeight(kg: Double) async throws {
        struct Body: Encodable { let weight_kg: Double }
        _ = try await post("weight", Body(weight_kg: kg), as: Empty.self)
    }

    func logWater(ml: Int) async throws -> Int {
        struct Body: Encodable { let ml: Int }
        struct Res: Decodable { let ml: Int }
        return try await post("water", Body(ml: ml), as: Res.self).ml
    }

    func verifySubscription(signedTransaction: String) async throws {
        struct Body: Encodable { let signed_transaction: String }
        _ = try await post("subscription/verify", Body(signed_transaction: signedTransaction), as: Empty.self)
    }
}
