import SwiftUI

// MARK: - Color Palette
extension Color {
    static let appBg        = Color(hex: "#09090E")
    static let surface      = Color(hex: "#14141A")
    static let surfaceLight = Color(hex: "#22222D")
    static let accentVisited  = Color(hex: "#10B981")
    static let accentUpcoming = Color(hex: "#F43F5E")
    static let accentSaved    = Color(hex: "#0EA5E9")
}

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >>  8) & 0xFF) / 255.0
        let b = Double( rgb        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - View Modifiers
struct GlassModifier: ViewModifier {
    var heavy: Bool = false
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    if heavy { Color.appBg.opacity(0.85) } else { Color.surface.opacity(0.6) }
                    Color.white.opacity(0.03)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .stroke(Color.white.opacity(heavy ? 0.05 : 0.08), lineWidth: 1)
            )
    }
}

extension View {
    func glassBackground(heavy: Bool = false) -> some View { modifier(GlassModifier(heavy: heavy)) }
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(
                ZStack {
                    Color.surface.opacity(0.6)
                    Color.white.opacity(0.02)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Data Models
enum RestaurantType: String, CaseIterable {
    case visited  = "visited"
    case upcoming = "upcoming"
    case wishlist = "wishlist"

    var color: Color {
        switch self {
        case .visited:  return .accentVisited
        case .upcoming: return .accentUpcoming
        case .wishlist: return .accentSaved
        }
    }
    var label: String {
        switch self {
        case .visited:  return "Visited"
        case .upcoming: return "Upcoming"
        case .wishlist: return "Wishlist"
        }
    }
}

struct Restaurant: Identifiable {
    let id = UUID()
    var dbId: String? = nil     // Supabase restaurants.id (UUID string)
    var yelpId: String? = nil   // Yelp business id or synthetic local id
    var visitRowId: String? = nil
    var wishlistRowId: String? = nil
    var savedFrom: String? = nil
    let name: String
    let location: String
    let imageURL: String
    let types: [RestaurantType]
    let rating: Double
    let lat: Double
    let lng: Double
    let visitDate: String
    let visitDateGroup: String
    var cuisineTag: String = "Restaurant"
    var cuisineTags: [String] = []
    var phoneNumber: String? = nil
    var websiteURL: String? = nil
    var reviewCount: Int? = nil
    var aboutText: String? = nil
    var hours: [String: String] = [:]
    var yelpReviews: [YelpReview] = []

    var primaryType: RestaurantType {
        if types.contains(.upcoming) { return .upcoming }
        if types.contains(.visited)  { return .visited  }
        return .wishlist
    }
    // A restaurant is "from DB" if it has a yelpId
    var isFromDB: Bool { yelpId != nil }
    var savedFromLabel: String {
        guard let savedFrom, !savedFrom.isEmpty else { return "Saved from App" }
        switch savedFrom.lowercased() {
        case "map": return "Saved from Map"
        case "instagram": return "Saved from Instagram"
        case "search": return "Saved from Search"
        case "app", "manual": return "Saved from App"
        default: return "Saved from \(savedFrom.capitalized)"
        }
    }
}
// MARK: - Helpers
func syntheticRestaurantId(name: String, latitude: Double, longitude: Double) -> String {
    let slug = name
        .lowercased()
        .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    let lat = String(format: "%.5f", latitude)
    let lng = String(format: "%.5f", longitude)
    return "manual_\(slug)_\(lat)_\(lng)"
}

// MARK: - Sample Data
// All data loaded from Supabase via AppState.shared
let sampleRestaurants: [Restaurant] = []
