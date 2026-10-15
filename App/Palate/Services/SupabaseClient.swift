import Foundation

// MARK: - Supabase Configuration
// Local values are loaded from a Git-ignored bundled configuration file.
struct SupabaseConfig {
    private static let values: [String: String] = {
        guard let fileURL = Bundle.main.url(forResource: "Supabase.local", withExtension: "plist"),
              let data = try? Data(contentsOf: fileURL),
              let config = try? PropertyListDecoder().decode([String: String].self, from: data) else {
            fatalError("Missing Supabase.local.plist. Follow the README configuration steps.")
        }
        return config
    }()

    private static func required(_ key: String) -> String {
        guard let value = values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fatalError("Missing Supabase configuration value for \(key).")
        }
        return value
    }

    static let url = required("SUPABASE_URL")
    static let anonKey = required("SUPABASE_ANON_KEY")
}

// MARK: - Supabase Client (lightweight, no SDK dependency)
class SupabaseClient {
    static let shared = SupabaseClient()

    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: "sb_access_token") }
        set { UserDefaults.standard.set(newValue, forKey: "sb_access_token") }
    }
    private var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: "sb_refresh_token") }
        set { UserDefaults.standard.set(newValue, forKey: "sb_refresh_token") }
    }
    var currentUserId: String? {
        get { UserDefaults.standard.string(forKey: "sb_user_id") }
        set { UserDefaults.standard.set(newValue, forKey: "sb_user_id") }
    }
    var currentUserEmail: String? {
        get { UserDefaults.standard.string(forKey: "sb_user_email") }
        set { UserDefaults.standard.set(newValue, forKey: "sb_user_email") }
    }
    var isAuthenticated: Bool { accessToken != nil && currentUserId != nil }

    // MARK: - HTTP helpers
    private func authHeaders() -> [String: String] {
        var h = ["Content-Type": "application/json", "apikey": SupabaseConfig.anonKey]
        if let token = accessToken { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    private func handleAuthFailure(statusCode: Int, data: Data) -> Bool {
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let message = (
            body["message"] as? String ??
            body["msg"] as? String ??
            body["error"] as? String ??
            ""
        ).lowercased()
        let expiredMarkers = ["jwt", "expired", "token", "unauthorized", "not authenticated", "forbidden"]
        guard statusCode == 401 || statusCode == 403 || expiredMarkers.contains(where: { message.contains($0) }) else {
            return false
        }
        signOut()
        clearPendingSession()
        NotificationCenter.default.post(name: .signOut, object: nil)
        return true
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard let url = URL(string: SupabaseConfig.url + path) else { throw PalateError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        authHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if method != "GET" && path.contains("/rest/v1/") { req.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer") }
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            if handleAuthFailure(statusCode: http.statusCode, data: data) {
                throw PalateError.notAuthenticated
            }
            throw PalateError.api(msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func requestRaw(_ path: String, method: String = "POST", body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: SupabaseConfig.url + path) else { throw PalateError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        authHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if method != "GET" && path.contains("/rest/v1/") { req.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer") }
        // Don't send an empty JSON body on DELETE — some Supabase REST routes reject it
        if method != "DELETE" || !body.isEmpty {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            if handleAuthFailure(statusCode: http.statusCode, data: data) {
                throw PalateError.notAuthenticated
            }
            throw PalateError.api(msg)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Auth
    // Temp tokens held in memory — NOT persisted until OTP confirmed
    var pendingAccessToken: String? = nil
    var pendingRefreshToken: String? = nil
    var pendingUserId: String? = nil
    var pendingUserEmail: String? = nil

    func signInWithPassword(email: String, password: String) async throws {
        let resp: AuthResponse = try await request(
            "/auth/v1/token?grant_type=password",
            method: "POST",
            body: ["email": email, "password": password]
        )
        // Hold in memory only — persisted only after OTP confirms
        pendingAccessToken = resp.access_token
        pendingRefreshToken = resp.refresh_token
        pendingUserId = resp.user?.id
        pendingUserEmail = resp.user?.email
    }

    func signUpWithPassword(email: String, password: String, username: String) async throws {
        let body: [String: Any] = ["email": email, "password": password, "data": ["username": username]]
        let resp: AuthResponse = try await request("/auth/v1/signup", method: "POST", body: body)
        pendingAccessToken = resp.access_token
        pendingRefreshToken = resp.refresh_token
        pendingUserId = resp.user?.id
        pendingUserEmail = resp.user?.email
    }

    // Call this to commit session after OTP verified
    func commitPendingSession() {
        accessToken = pendingAccessToken
        refreshToken = pendingRefreshToken
        currentUserId = pendingUserId
        currentUserEmail = pendingUserEmail
        pendingAccessToken = nil
        pendingRefreshToken = nil
        pendingUserId = nil
        pendingUserEmail = nil
    }

    func clearPendingSession() {
        pendingAccessToken = nil; pendingRefreshToken = nil
        pendingUserId = nil; pendingUserEmail = nil
    }

    func sendOTP(email: String) async throws {
        // Do NOT send create_user:false — that blocks OTP for brand-new accounts.
        // Supabase defaults to true which works for both existing and new users.
        _ = try await requestRaw("/auth/v1/otp", body: ["email": email])
    }

    func verifyOTP(email: String, token: String) async throws -> AuthResponse {
        let resp: AuthResponse = try await request(
            "/auth/v1/verify",
            method: "POST",
            body: ["email": email, "token": token, "type": "email"]
        )
        // OTP verified — now persist the session
        accessToken = resp.access_token ?? pendingAccessToken
        refreshToken = resp.refresh_token ?? pendingRefreshToken
        currentUserId = resp.user?.id ?? pendingUserId
        currentUserEmail = resp.user?.email ?? pendingUserEmail
        clearPendingSession()
        return resp
    }

    func refreshSession() async throws {
        guard let rt = refreshToken else { throw PalateError.notAuthenticated }
        let resp: AuthResponse = try await request(
            "/auth/v1/token?grant_type=refresh_token",
            method: "POST",
            body: ["refresh_token": rt]
        )
        accessToken = resp.access_token
        refreshToken = resp.refresh_token
    }

    func signOut() {
        accessToken = nil; refreshToken = nil; currentUserId = nil; currentUserEmail = nil
    }

    // MARK: - Edge Functions
    func searchRestaurants(query: String, lat: Double, lng: Double, limit: Int = 20) async throws -> [RemoteRestaurant] {
        let resp: SearchResponse = try await request(
            "/functions/v1/search-restaurants",
            method: "POST",
            body: ["query": query, "lat": lat, "lng": lng, "limit": limit]
        )
        return resp.restaurants
    }

    func restaurantDetail(yelpId: String) async throws -> RestaurantDetailResponse {
        return try await request(
            "/functions/v1/restaurant-detail",
            method: "POST",
            body: ["yelp_id": yelpId]
        )
    }

    func logVisit(_ entry: LogVisitRequest) async throws -> LogVisitResponse {
        return try await request("/functions/v1/log-visit", method: "POST", body: entry.toDict())
    }

    func scheduleReminder(reservationId: String, restaurantName: String, datetime: Date, hoursBefore: Double = 3) async throws {
        let iso = ISO8601DateFormatter().string(from: datetime)
        _ = try await requestRaw("/functions/v1/schedule-reminder", body: [
            "reservation_id": reservationId,
            "restaurant_name": restaurantName,
            "reservation_datetime": iso,
            "hours_before": hoursBefore
        ])
    }

    func fetchStats() async throws -> UserStats {
        return try await request("/functions/v1/stats")
    }

    func fetchFeed(before: Date? = nil, limit: Int = 20) async throws -> FeedResponse {
        // feed is GET — params must be query string, not body
        var components = URLComponents(string: SupabaseConfig.url + "/functions/v1/feed")!
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let before { queryItems.append(URLQueryItem(name: "before", value: ISO8601DateFormatter().string(from: before))) }
        components.queryItems = queryItems
        guard let url = components.url else { throw PalateError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        authHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            if handleAuthFailure(statusCode: http.statusCode, data: data) { throw PalateError.notAuthenticated }
            throw PalateError.api(msg)
        }
        return try JSONDecoder().decode(FeedResponse.self, from: data)
    }

    func fetchProfileDetails() async throws -> ProfileDetailsResponse {
        return try await request("/functions/v1/profile-details")
    }

    func fetchContactItems(userId: String) async throws -> [ContactItemRecord] {
        // Route through edge function — direct REST bypasses RLS for anon clients
        let details = try await fetchProfileDetails()
        return details.contact_items_flat
            ?? details.contact_items?.values.flatMap { $0 }
            ?? []
    }

    func replaceContactItems(userId: String, type: String, items: [ContactItem]) async throws {
        let current = try await fetchProfileDetails()
        let existingIds = (current.contact_items_flat ?? current.contact_items?.values.flatMap { $0 } ?? [])
            .filter { $0.type.lowercased() == type.lowercased() }
            .map { $0.id }
        for id in existingIds { try await deleteProfileContactItem(contactItemId: id) }
        guard !items.isEmpty else { return }
        _ = try await saveProfileContactItems(type: type, items: items)
    }

    func deleteContactItem(contactItemId: String) async throws {
        _ = try await requestRaw(
            "/functions/v1/profile-details",
            method: "DELETE",
            body: ["contact_item_id": contactItemId]
        )
    }

    func markNotificationRead(notificationId: String) async throws {
        _ = try await requestRaw(
            "/rest/v1/notifications?id=eq.\(notificationId)",
            method: "PATCH",
            body: ["is_read": true]
        )
    }

    func deleteNotification(notificationId: String) async throws {
        _ = try await requestRaw(
            "/functions/v1/notifications",
            method: "DELETE",
            body: ["notification_id": notificationId]
        )
    }

    func markAllNotificationsRead(userId: String) async throws {
        let current = try await fetchNotifications()
        let unreadIds = current.items.filter { $0.is_read == false }.map { $0.id }
        for id in unreadIds { try await markNotificationRead(notificationId: id) }
    }

    // MARK: - REST API (direct table access)
    func fetchVisits(userId: String) async throws -> [VisitRow] {
        return try await request("/rest/v1/visits?user_id=eq.\(userId)&order=visit_date.desc&select=*,restaurants(*)")
    }

    func fetchWishlist(userId: String) async throws -> [WishlistRow] {
        return try await request("/rest/v1/wishlists?user_id=eq.\(userId)&select=*,restaurants(*)")
    }
    func createWishlistRow(userId: String, restaurantId: String, savedFrom: String) async throws -> WishlistRow {
        let rows: [WishlistRow] = try await request(
            "/rest/v1/wishlists",
            method: "POST",
            body: [
                "user_id": userId,
                "restaurant_id": restaurantId,
                "saved_from": savedFrom
            ]
        )
        guard let row = rows.first else { throw PalateError.notFound }
        return row
    }

    func deleteVisit(visitId: String) async throws {
        _ = try await requestRaw("/functions/v1/log-visit", method: "DELETE", body: ["visit_id": visitId])
    }

    func deleteWishlistRow(rowId: String) async throws {
        // Don't use requestRaw with body:[:] for DELETE — send a clean bodyless request
        guard let url = URL(string: SupabaseConfig.url + "/rest/v1/wishlists?id=eq.\(rowId)") else { throw PalateError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        authHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (_, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PalateError.api("HTTP \(http.statusCode)")
        }
    }

    func fetchProfile(userId: String) async throws -> ProfileRow {
        let rows: [ProfileRow] = try await request("/rest/v1/profiles?id=eq.\(userId)&select=*")
        guard let profile = rows.first else { throw PalateError.notFound }
        return profile
    }

    func fetchNotifications() async throws -> NotificationsResponse {
        return try await request("/functions/v1/notifications")
    }

    func saveProfileContactItems(type: String, items: [ContactItem]) async throws -> ProfileDetailsResponse {
        let body: [String: Any] = [
            "items": items.map { [
                "type": type,
                "value": $0.value,
                "is_primary": $0.isPrimary
            ] }
        ]
        return try await request("/functions/v1/profile-details", method: "POST", body: body)
    }

    func deleteProfileContactItem(contactItemId: String) async throws {
        _ = try await requestRaw(
            "/functions/v1/profile-details",
            method: "DELETE",
            body: ["contact_item_id": contactItemId]
        )
    }

    // Expose requestRaw publicly for AppState
    func requestRawPublic(_ path: String, method: String = "POST", body: [String: Any]) async throws -> [String: Any] {
        try await requestRaw(path, method: method, body: body)
    }

    func upsertRestaurant(_ restaurant: Restaurant, yelpId: String? = nil) async throws -> RestaurantRecord {
        let resolvedYelpId = yelpId ?? restaurant.yelpId ?? Self.syntheticYelpId(for: restaurant)
        var body: [String: Any] = [
            "yelp_id": resolvedYelpId,
            "name": restaurant.name,
            "address": restaurant.location,
            "lat": restaurant.lat,
            "lng": restaurant.lng,
            "rating": restaurant.rating,
            "image_url": restaurant.imageURL
        ]
        if let phone = restaurant.phoneNumber { body["phone"] = phone }
        if let websiteURL = restaurant.websiteURL { body["yelp_url"] = websiteURL }
        if !restaurant.cuisineTags.isEmpty { body["cuisine_tags"] = restaurant.cuisineTags }
        if !restaurant.hours.isEmpty { body["hours"] = restaurant.hours }
        let rows: [RestaurantRecord] = try await request(
            "/rest/v1/restaurants?on_conflict=yelp_id",
            method: "POST",
            body: body
        )
        guard let row = rows.first else { throw PalateError.notFound }
        return row
    }

    func ensureRestaurantId(for restaurant: Restaurant) async throws -> String {
        let row = try await upsertRestaurant(restaurant)
        return row.id
    }

    private static func syntheticYelpId(for restaurant: Restaurant) -> String {
        let slug = restaurant.name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let lat = String(format: "%.5f", restaurant.lat)
        let lng = String(format: "%.5f", restaurant.lng)
        return "manual_\(slug)_\(lat)_\(lng)"
    }

    func registerPushToken(_ token: String) async throws {
        guard let userId = currentUserId else { return }
        // Use upsert so re-registering the same token (app reinstall, etc.) doesn't 409
        _ = try await requestRaw("/rest/v1/push_tokens?on_conflict=user_id,device_token", body: [
            "user_id": userId,
            "device_token": token,
            "platform": "ios"
        ])
    }
}

// MARK: - Models
struct AuthResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let user: AuthUser?
}
struct AuthUser: Decodable {
    let id: String
    let email: String?
}

struct RemoteRestaurant: Decodable, Identifiable {
    let id: String
    let yelp_id: String
    let name: String
    let address: String?
    let city: String?
    let state: String?
    let country: String?
    let phone: String?
    let yelp_url: String?
    let description: String?
    let lat: Double?
    let lng: Double?
    let rating: Double?
    let review_count: Int?
    let price_range: String?
    let cuisine_tags: [String]?
    let image_url: String?
    let is_open_now: Bool?
    let distance_meters: Double?
    let hours: [String: String]?

    // Convert to local Restaurant model
    func toRestaurant() -> Restaurant {
        let mockImages = [
            "https://images.unsplash.com/photo-1550966871-3ed3cdb5ed0c?q=80&w=800&auto=format&fit=crop",
            "https://images.unsplash.com/photo-1414235077428-338989a2e8c0?q=80&w=800&auto=format&fit=crop",
            "https://images.unsplash.com/photo-1504674900247-0877df9cc836?q=80&w=800&auto=format&fit=crop",
        ]
        let img = image_url ?? mockImages[abs(name.hashValue) % mockImages.count]
        let tags = cuisine_tags ?? []
        return Restaurant(
            dbId: id,
            yelpId: yelp_id,
            name: name,
            location: [address, city].compactMap { $0 }.joined(separator: ", "),
            imageURL: img,
            types: [.wishlist],
            rating: rating ?? 4.0,
            lat: lat ?? 0,
            lng: lng ?? 0,
            visitDate: "", visitDateGroup: "",
            cuisineTag: tags.first ?? price_range ?? "Restaurant",
            cuisineTags: tags,
            phoneNumber: phone,
            websiteURL: yelp_url,
            reviewCount: review_count,
            aboutText: description,
            hours: hours ?? [:]
        )
    }
}

struct SearchResponse: Decodable {
    let restaurants: [RemoteRestaurant]
    let total: Int?
}

struct RestaurantDetailResponse: Decodable {
    let restaurant: RemoteRestaurant?
    let hours: [String: String]?
    let yelp_reviews: [YelpReview]?
    let user_visit_count: Int?
    let user_last_visited: String?
}

struct YelpReview: Decodable, Identifiable {
    var id: String { author + time_created }
    let author: String
    let rating: Int
    let text: String
    let time_created: String
}

struct RestaurantRecord: Decodable {
    let id: String
    let yelp_id: String
}

struct LogVisitRequest {
    let restaurantId: String
    let visitType: String  // "visited" | "upcoming" | "wishlist"
    let visitDate: String  // "YYYY-MM-DD"
    let visitTime: String  // "HH:MM"
    let partySize: Int
    let rating: Double
    let notes: String
    let dishes: [[String: Any]]

    func toDict() -> [String: Any] {
        ["restaurant_id": restaurantId, "visit_type": visitType,
         "visit_date": visitDate, "visit_time": visitTime,
         "party_size": partySize, "rating": rating,
         "notes": notes, "dishes": dishes]
    }
}

struct LogVisitResponse: Decodable {
    let visit_id: String
    let streak_count: Int?
    let milestone: String?
    let points_earned: Int?
}

struct UserStats: Decodable {
    let total_visits: Int
    let unique_cuisines: Int
    let total_miles_traveled: Double
    let current_streak_weeks: Int
    let favorite_cuisine: String?
    let milestones: [String]?
}

struct FeedResponse: Decodable {
    let items: [FeedItem]
    let has_more: Bool
}

struct NotificationsResponse: Decodable {
    let items: [NotificationFeedRow]
    let has_more: Bool?
}

struct FeedItem: Decodable, Identifiable {
    let id: String
    let type: String
    let actor: FeedActor
    let restaurant: FeedRestaurant?
    let rating: Double?
    let created_at: String
}
struct FeedActor: Decodable { let username: String; let avatar_url: String? }
struct FeedRestaurant: Decodable { let name: String; let city: String?; let image_url: String? }

struct AppNotificationItem: Identifiable {
    let id: String
    let type: String
    let title: String
    let message: String
    let logoURL: String?
    let time: String
    let isRead: Bool
}

struct ContactItemRecord: Decodable {
    let id: String
    let type: String
    let value: String
    let is_primary: Bool
}

struct ProfileDetailsResponse: Decodable {
    let profile: ProfileRow?
    let contact_items: [String: [ContactItemRecord]]?
    let contact_items_flat: [ContactItemRecord]?
}

struct NotificationRestaurant: Decodable {
    let id: String?
    let name: String?
    let image_url: String?
}

struct NotificationVisit: Decodable {
    let id: String?
    let visit_type: String?
    let visit_date: String?
    let visit_time: String?
}

struct NotificationFeedRow: Decodable, Identifiable {
    let id: String
    let type: String
    let title: String?
    let body: String?
    let logo_url: String?
    let is_read: Bool?
    let created_at: String
    let restaurant: NotificationRestaurant?
    let visit: NotificationVisit?
}

struct VisitRow: Decodable, Identifiable {
    let id: String
    let visit_type: String
    let visit_date: String?
    let visit_time: String?
    let party_size: Int?
    let rating: Double?
    let notes: String?
    let source: String?
    let restaurants: RemoteRestaurant?
}

struct WishlistRow: Decodable, Identifiable {
    let id: String
    let saved_at: String
    let saved_from: String?
    let restaurants: RemoteRestaurant?
}

struct ProfileRow: Decodable {
    let id: String
    let username: String?
    let display_name: String?
    let avatar_url: String?
    let total_visits: Int?
    let is_pro: Bool?
}

// MARK: - Errors
enum PalateError: LocalizedError {
    case invalidURL, notAuthenticated, notFound, api(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .notAuthenticated: return "Not signed in"
        case .notFound: return "Not found"
        case .api(let msg): return msg
        }
    }
}
