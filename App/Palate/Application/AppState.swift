import SwiftUI
import Combine

fileprivate func normalizeCuisineTags(_ tags: [String]?, fallback: String? = nil) -> [String] {
    let cleaned = (tags ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if !cleaned.isEmpty { return cleaned }
    if let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty, fallback != "Restaurant" {
        return [fallback]
    }
    return []
}

fileprivate func cuisineDisplayText(_ tags: [String]?, fallback: String? = nil) -> String? {
    let cleaned = normalizeCuisineTags(tags, fallback: fallback)
    return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
}

// MARK: - Central app state — single source of truth for DB data
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var visitRows: [VisitRow] = []
    @Published var visitedRestaurants: [Restaurant] = []
    @Published var upcomingRestaurants: [Restaurant] = []
    @Published var wishlistRestaurants: [Restaurant] = []
    @Published var isLoading = false
    @Published var stats: UserStats? = nil
    @Published var profileRow: ProfileRow? = nil
    @Published var emailContacts: [ContactItem] = []
    @Published var instagramContacts: [ContactItem] = []
    @Published var phoneContacts: [ContactItem] = []
    @Published var notifications: [AppNotificationItem] = []

    // MARK: - Load all data from Supabase
    func loadAll() async {
        guard let userId = SupabaseClient.shared.currentUserId else { return }
        await MainActor.run { isLoading = true }

        async let visitsTask = SupabaseClient.shared.fetchVisits(userId: userId)
        async let wishlistTask = SupabaseClient.shared.fetchWishlist(userId: userId)
        async let statsTask = SupabaseClient.shared.fetchStats()
        async let detailsTask = SupabaseClient.shared.fetchProfileDetails()
        async let notificationsTask = SupabaseClient.shared.fetchNotifications()

        let fetchedVisits = try? await visitsTask
        let fetchedWishlist = try? await wishlistTask
        let fetchedStats = try? await statsTask
        let profileDetails = try? await detailsTask
        let fetchedNotifications = try? await notificationsTask

        await MainActor.run {
            isLoading = false

            if let fetchedVisits {
                visitRows = fetchedVisits
                visitedRestaurants = fetchedVisits.filter { $0.visit_type == "visited" }.compactMap { $0.toRestaurant() }
                upcomingRestaurants = fetchedVisits.filter { $0.visit_type == "upcoming" }.compactMap { $0.toRestaurant() }
            }

            if let fetchedWishlist {
                wishlistRestaurants = fetchedWishlist.compactMap { $0.toRestaurant() }
            }

            if let fetchedStats {
                let sourceVisits = fetchedVisits ?? visitRows
                stats = buildDerivedStats(from: sourceVisits, fallback: fetchedStats)
            } else if fetchedVisits != nil {
                stats = buildDerivedStats(from: visitRows, fallback: stats)
            }

            if let profileDetails {
                profileRow = profileDetails.profile
                applyContacts(contactRecords(from: profileDetails))
            }

            if let fetchedNotifications {
                notifications = mapNotifications(fetchedNotifications.items)
            }
        }
    }

    func refreshContacts() async {
        guard let profileDetails = try? await SupabaseClient.shared.fetchProfileDetails() else { return }
        await MainActor.run {
            profileRow = profileDetails.profile
            applyContacts(contactRecords(from: profileDetails))
        }
    }

    func refreshNotifications() async {
        guard let fetched = try? await SupabaseClient.shared.fetchNotifications() else { return }
        await MainActor.run { notifications = mapNotifications(fetched.items) }
    }

    func saveContactItems(type: String, items: [ContactItem]) async {
        let normalizedItems = items
            .map { ContactItem(id: $0.id, value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines), isPrimary: $0.isPrimary) }
            .filter { !$0.value.isEmpty }
        guard SupabaseClient.shared.currentUserId != nil else { return }
        do {
            let currentDetails = try await SupabaseClient.shared.fetchProfileDetails()
            let existingIds = contactRecords(from: currentDetails)
                .filter { $0.type.lowercased() == type.lowercased() }
                .map { $0.id }
            for contactItemId in existingIds {
                try await SupabaseClient.shared.deleteProfileContactItem(contactItemId: contactItemId)
            }
            if !normalizedItems.isEmpty {
                _ = try await SupabaseClient.shared.saveProfileContactItems(type: type, items: normalizedItems)
            }
            await refreshContacts()
        } catch {
            print("Save contact items error: \(error)")
        }
    }

    func deleteContactItem(contactItemId: String) async {
        do {
            try await SupabaseClient.shared.deleteProfileContactItem(contactItemId: contactItemId)
            await refreshContacts()
        } catch {
            print("Delete contact item error: \(error)")
        }
    }

    func markNotificationRead(notificationId: String) async {
        // Optimistically update local state first
        await MainActor.run {
            if let idx = notifications.firstIndex(where: { $0.id == notificationId }) {
                let n = notifications[idx]
                notifications[idx] = AppNotificationItem(
                    id: n.id, type: n.type, title: n.title,
                    message: n.message, logoURL: n.logoURL,
                    time: n.time, isRead: true
                )
            }
        }
        do {
            try await SupabaseClient.shared.markNotificationRead(notificationId: notificationId)
        } catch {
            print("Mark notification read error: \(error)")
            await refreshNotifications() // revert on failure
        }
    }

    func deleteNotification(notificationId: String) async {
        // Optimistically remove from local list immediately
        await MainActor.run {
            notifications.removeAll { $0.id == notificationId }
        }
        do {
            try await SupabaseClient.shared.deleteNotification(notificationId: notificationId)
        } catch {
            print("Delete notification error: \(error)")
            await refreshNotifications() // revert on failure
        }
    }

    func clearNotifications() async {
        let unreadIds = await MainActor.run { notifications.filter { !$0.isRead }.map { $0.id } }
        // Optimistically mark all read locally
        await MainActor.run {
            notifications = notifications.map { n in
                AppNotificationItem(id: n.id, type: n.type, title: n.title,
                                    message: n.message, logoURL: n.logoURL,
                                    time: n.time, isRead: true)
            }
        }
        do {
            for notificationId in unreadIds {
                try await SupabaseClient.shared.markNotificationRead(notificationId: notificationId)
            }
        } catch {
            print("Clear notifications error: \(error)")
            await refreshNotifications() // revert on failure
        }
    }

    private func contactRecords(from details: ProfileDetailsResponse?) -> [ContactItemRecord] {
        if let flat = details?.contact_items_flat, !flat.isEmpty { return flat }
        if let grouped = details?.contact_items {
            return grouped.values.flatMap { $0 }
        }
        return []
    }

    private func applyContacts(_ rows: [ContactItemRecord]) {
        let grouped = Dictionary(grouping: rows, by: { $0.type.lowercased() })
        emailContacts = (grouped["email"] ?? []).map { ContactItem(id: $0.id, value: $0.value, isPrimary: $0.is_primary) }
        instagramContacts = (grouped["instagram"] ?? []).map { ContactItem(id: $0.id, value: $0.value, isPrimary: $0.is_primary) }
        phoneContacts = (grouped["phone"] ?? []).map { ContactItem(id: $0.id, value: $0.value, isPrimary: $0.is_primary) }
    }

    private func mapNotifications(_ rows: [NotificationFeedRow]) -> [AppNotificationItem] {
        rows.map { row in
            AppNotificationItem(
                id: row.id,
                type: row.type,
                title: row.title ?? defaultNotificationTitle(for: row),
                message: row.body ?? defaultNotificationBody(for: row),
                logoURL: row.logo_url ?? row.restaurant?.image_url,
                time: relativeTime(from: row.created_at),
                isRead: row.is_read ?? false
            )
        }
    }

    private func defaultNotificationTitle(for row: NotificationFeedRow) -> String {
        let restaurantName = row.restaurant?.name ?? "Restaurant"
        switch row.type.lowercased() {
        case "email_import":        return "\(restaurantName) added via email"
        case "email_import_failed": return "Email format not supported"
        case "new_visit":           return "\(restaurantName) visited"
        case "new_wishlist":        return "\(restaurantName) saved"
        case "milestone":           return "Milestone reached"
        default:                    return restaurantName
        }
    }

    private func defaultNotificationBody(for row: NotificationFeedRow) -> String {
        switch row.type.lowercased() {
        case "email_import":        return row.visit?.visit_type == "upcoming" ? "Added to Next Up" : "Added to Recently Visited"
        case "email_import_failed": return "We couldn't read the restaurant from this email. Please log manually."
        case "new_visit":           return row.visit?.visit_date.map { "Visited on \($0)" } ?? "New visit added"
        case "new_wishlist":        return "Added to your wishlist"
        case "milestone":           return "Keep it up!"
        default:                    return row.body ?? "Activity update"
        }
    }

    private func relativeTime(from iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: iso) ?? Date()
        let interval = Date().timeIntervalSince(date)
        switch interval {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(interval / 60))m ago"
        case ..<86400: return "\(Int(interval / 3600))h ago"
        default:
            let days = Int(interval / 86400)
            return days == 1 ? "1d ago" : "\(days)d ago"
        }
    }

    private func buildDerivedStats(from visitRows: [VisitRow], fallback: UserStats?) -> UserStats {
        let visited = visitRows.filter { $0.visit_type == "visited" }
        let totalVisits = visited.count

        let cuisineTags = visited.flatMap { normalizeCuisineTags($0.restaurants?.cuisine_tags, fallback: $0.restaurants?.price_range) }
        let cuisineCounts = Dictionary(grouping: cuisineTags, by: { $0 }).mapValues { $0.count }
        let uniqueCuisineCount = Set(cuisineTags).count
        let favoriteCuisine = cuisineCounts.max(by: { $0.value < $1.value })?.key ?? fallback?.favorite_cuisine

        let streakWeeks = currentStreakWeeks(from: visited.compactMap { $0.visit_date })
        let derivedMilestones = deriveMilestones(totalVisits: totalVisits, streakWeeks: streakWeeks)

        return UserStats(
            total_visits: totalVisits,
            unique_cuisines: uniqueCuisineCount,
            total_miles_traveled: fallback?.total_miles_traveled ?? 0,
            current_streak_weeks: streakWeeks,
            favorite_cuisine: favoriteCuisine,
            milestones: derivedMilestones.isEmpty ? fallback?.milestones : derivedMilestones
        )
    }

    private func currentStreakWeeks(from dateStrings: [String]) -> Int {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"

        let cal = Calendar(identifier: .gregorian)
        let weekKeys: Set<String> = Set(dateStrings.compactMap { str in
            guard let date = fmt.date(from: str) else { return nil }
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            guard let year = comps.yearForWeekOfYear, let week = comps.weekOfYear else { return nil }
            return "\(year)-\(week)"
        })

        guard !weekKeys.isEmpty else { return 0 }
        let sortedWeeks = weekKeys.compactMap { key -> (Int, Int)? in
            let parts = key.split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), let week = Int(parts[1]) else { return nil }
            return (year, week)
        }.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 > rhs.1 : lhs.0 > rhs.0
        }

        guard let first = sortedWeeks.first else { return 0 }
        var streak = 1
        var previousYear = first.0
        var previousWeek = first.1

        for current in sortedWeeks.dropFirst() {
            let expected = previousWeek - 1
            if current.0 == previousYear && current.1 == expected {
                streak += 1
                previousYear = current.0
                previousWeek = current.1
                continue
            }
            if current.0 == previousYear - 1 && previousWeek == 1 {
                let cal = Calendar(identifier: .gregorian)
                let lastWeekOfPrevYear = cal.component(.weekOfYear, from: cal.date(from: DateComponents(year: previousYear - 1, month: 12, day: 28)) ?? Date())
                if current.1 == lastWeekOfPrevYear {
                    streak += 1
                    previousYear = current.0
                    previousWeek = current.1
                    continue
                }
            }
            break
        }
        return streak
    }

    private func deriveMilestones(totalVisits: Int, streakWeeks: Int) -> [String] {
        var milestones: [String] = []
        if totalVisits >= 1 { milestones.append("first_visit") }
        if totalVisits >= 10 { milestones.append("10_visits") }
        if totalVisits >= 50 { milestones.append("50_visits") }
        if totalVisits >= 100 { milestones.append("100_visits") }
        if streakWeeks >= 7 { milestones.append("streak_7_weeks") }
        return milestones
    }

    // MARK: - Wishlist CRUD
    private func resolvedSavedFrom(for restaurant: Restaurant) -> String {
        if let savedFrom = restaurant.savedFrom?.lowercased(), !savedFrom.isEmpty {
            return savedFrom
        }
        if restaurant.yelpId?.hasPrefix("manual_") == true { return "map" }
        return "app"
    }

    func saveToWishlist(_ restaurant: Restaurant) async {
        guard let userId = SupabaseClient.shared.currentUserId else { return }
        do {
            let record = try await SupabaseClient.shared.upsertRestaurant(restaurant)
            let savedFrom = resolvedSavedFrom(for: restaurant)
            let wishlistRow = try await SupabaseClient.shared.createWishlistRow(
                userId: userId,
                restaurantId: record.id,
                savedFrom: savedFrom
            )

            await MainActor.run {
                var savedRestaurant = restaurant
                savedRestaurant.dbId = record.id
                savedRestaurant.wishlistRowId = wishlistRow.id
                savedRestaurant.savedFrom = wishlistRow.saved_from ?? savedFrom
                if savedRestaurant.yelpId == nil { savedRestaurant.yelpId = record.yelp_id }
                if !wishlistRestaurants.contains(where: { $0.dbId == record.id || $0.name == savedRestaurant.name }) {
                    wishlistRestaurants.append(savedRestaurant)
                }
            }
            await loadAll()
        } catch { print("Save wishlist error: \(error)") }
    }

    func removeFromWishlist(_ restaurant: Restaurant) async {
        guard let userId = SupabaseClient.shared.currentUserId else { return }
        do {
            if let rowId = restaurant.wishlistRowId {
                try await SupabaseClient.shared.deleteWishlistRow(rowId: rowId)
            } else if let restaurantId = restaurant.dbId {
                _ = try await SupabaseClient.shared.requestRawPublic(
                    "/rest/v1/wishlists?user_id=eq.\(userId)&restaurant_id=eq.\(restaurantId)",
                    method: "DELETE",
                    body: [:]
                )
            }
            await MainActor.run {
                wishlistRestaurants.removeAll {
                    ($0.wishlistRowId != nil && $0.wishlistRowId == restaurant.wishlistRowId) ||
                    ($0.dbId != nil && $0.dbId == restaurant.dbId) ||
                    $0.id == restaurant.id
                }
            }
            await loadAll()
        } catch { print("Remove wishlist error: \(error)") }
    }

    func deleteVisit(_ restaurant: Restaurant) async {
        guard SupabaseClient.shared.currentUserId != nil else { return }
        let rowId = restaurant.visitRowId ?? visitRows.first(where: { row in
            guard row.visit_type == "visited" || row.visit_type == "upcoming" else { return false }
            if let dbId = restaurant.dbId, row.restaurants?.id == dbId { return true }
            if let yelpId = restaurant.yelpId, row.restaurants?.yelp_id == yelpId { return true }
            return row.restaurants?.name.lowercased() == restaurant.name.lowercased()
        })?.id
        guard let rowId else { return }
        do {
            if let row = visitRows.first(where: { $0.id == rowId }), row.visit_type == "upcoming",
               let visitDate = row.visit_date {
                let fmt = DateFormatter()
                fmt.calendar = Calendar(identifier: .gregorian)
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.timeZone = TimeZone.current
                fmt.dateFormat = "yyyy-MM-dd HH:mm"
                let dateText = "\(visitDate) \(row.visit_time ?? "19:00")"
                if let date = fmt.date(from: dateText) {
                    NotificationManager.shared.cancelReservationReminder(restaurantName: row.restaurants?.name ?? restaurant.name, date: date)
                }
            }

            try await SupabaseClient.shared.deleteVisit(visitId: rowId)
            await MainActor.run {
                visitRows.removeAll { $0.id == rowId }
                visitedRestaurants.removeAll {
                    ($0.visitRowId != nil && $0.visitRowId == rowId) || $0.id == restaurant.id
                }
                upcomingRestaurants.removeAll {
                    ($0.visitRowId != nil && $0.visitRowId == rowId) || $0.id == restaurant.id
                }
            }
            await loadAll()
        } catch { print("Delete visit error: \(error)") }
    }

    func isWishlisted(_ restaurant: Restaurant) -> Bool {
        wishlistRestaurants.contains {
            ($0.dbId != nil && $0.dbId == restaurant.dbId) ||
            ($0.yelpId != nil && $0.yelpId == restaurant.yelpId) ||
            $0.name == restaurant.name
        }
    }
}

// MARK: - VisitRow → Restaurant conversion
extension VisitRow {
    func toRestaurant() -> Restaurant? {
        guard let r = restaurants else { return nil }
        var restaurant = r.toRestaurant(visitType: visit_type, visitDate: visit_date ?? "")
        restaurant.visitRowId = id
        restaurant.savedFrom = source
        return restaurant
    }
}

extension WishlistRow {
    func toRestaurant() -> Restaurant? {
        var restaurant = restaurants?.toRestaurant(visitType: "wishlist", visitDate: "")
        restaurant?.wishlistRowId = id
        restaurant?.savedFrom = saved_from
        return restaurant
    }
}

extension RemoteRestaurant {
    func toRestaurant(visitType: String = "wishlist", visitDate: String = "") -> Restaurant {
        let type: RestaurantType
        switch visitType {
        case "visited":  type = .visited
        case "upcoming": type = .upcoming
        default:         type = .wishlist
        }
        let mockImages = [
            "https://images.unsplash.com/photo-1550966871-3ed3cdb5ed0c?q=80&w=800&auto=format&fit=crop",
            "https://images.unsplash.com/photo-1414235077428-338989a2e8c0?q=80&w=800&auto=format&fit=crop",
            "https://images.unsplash.com/photo-1504674900247-0877df9cc836?q=80&w=800&auto=format&fit=crop",
        ]
        let img = image_url ?? mockImages[abs(name.hashValue) % mockImages.count]
        let group = visitDate.isEmpty ? "" : String(visitDate.prefix(7)) // "2026-04"
        let tags = normalizeCuisineTags(cuisine_tags, fallback: price_range)
        return Restaurant(
            dbId: id,
            yelpId: yelp_id,
            name: name,
            location: [address, city].compactMap { $0 }.joined(separator: ", "),
            imageURL: img,
            types: [type],
            rating: rating ?? 4.0,
            lat: lat ?? 0,
            lng: lng ?? 0,
            visitDate: visitDate,
            visitDateGroup: group,
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
