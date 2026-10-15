import SwiftUI
import MapKit

struct RestaurantDetailOverlay: View {
    let restaurant: Restaurant
    @Binding var isPresented: Bool
    var showToast: (String) -> Void
    var onLogThis: () -> Void
    var onShowOnMap: (Restaurant) -> Void

    @ObservedObject private var appState = AppState.shared
    @State private var isSaved = false  // set on appear from AppState, not from primaryType
    @State private var activeTab = 0
    @State private var showCancelReservation = false
    @State private var dontRemindCancel = false
    @State private var showShareSheet = false
    @State private var showAllVisits = false
    @State private var detailResponse: RestaurantDetailResponse? = nil
    @State private var isLoadingDetail = false

    // MARK: - Body
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.appBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        heroSection(geo: geo)
                        contentSection(geo: geo)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // Check real saved state from AppState — NOT from primaryType
            isSaved = AppState.shared.isWishlisted(restaurant)
            Task { await loadRestaurantDetail() }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [
                URL(string: "https://maps.apple.com/?q=\(restaurant.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&ll=\(restaurant.lat),\(restaurant.lng)")
                ?? URL(string: "https://maps.apple.com")!
            ])
        }
        .overlay(cancelOverlay)
        .overlay(allVisitsOverlay)
    }

    // MARK: - Hero
    @ViewBuilder
    private func heroSection(geo: GeometryProxy) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: restaurant.imageURL)) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.surfaceLight }
            .frame(width: geo.size.width, height: 340).clipped()

            LinearGradient(
                colors: [Color.clear, Color.appBg.opacity(0.6), Color.appBg],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: geo.size.width, height: 340)

            heroOverlayContent
                .padding(.leading, geo.safeAreaInsets.leading + 20)
                .padding(.trailing, geo.safeAreaInsets.trailing + 20)
                .padding(.bottom, 24)
        }
        .frame(width: geo.size.width, height: 340)
    }

    @ViewBuilder
    private var heroOverlayContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            backButton.padding(.bottom, 8)
            typeBadge
            nameRatingRow
            Text(restaurant.location)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray).lineLimit(1)
        }
    }

    private var backButton: some View {
        Button(action: { withAnimation { isPresented = false } }) {
            Image(systemName: "arrow.left")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.6)).clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    private var typeBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(restaurant.primaryType.color)
                .frame(width: 6, height: 6)
                .shadow(color: restaurant.primaryType.color, radius: 4)
            Text(restaurant.primaryType.label.uppercased())
                .font(.system(size: 9, weight: .bold)).foregroundColor(.white).tracking(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.1)).clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var nameRatingRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(restaurant.name)
                .font(.system(size: 30, weight: .black)).foregroundColor(.white).tracking(-0.5)
            ratingBadge
        }
    }

    private var ratingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 10)).foregroundColor(.accentVisited)
                .shadow(color: Color.accentVisited.opacity(0.5), radius: 3)
            Text(String(format: "%.1f", restaurant.rating))
                .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.surface.opacity(0.8))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Content Section
    @ViewBuilder
    private func contentSection(geo: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            bookTableButton
            quickActionsGrid
            if restaurant.primaryType == .upcoming { cancelReservationButton }
            phoneButton
            viewAllVisitsButton
            Spacer().frame(height: 8)
            tabRowView
            tabContent
        }
        .padding(.leading, geo.safeAreaInsets.leading + 20)
        .padding(.trailing, geo.safeAreaInsets.trailing + 20)
        .padding(.top, 12)
        .padding(.bottom, 80)
    }

    private var bookTableButton: some View {
        HStack(spacing: 8) {
            Image(systemName: "fork.knife").font(.system(size: 14)).opacity(0.4)
            Text("Book Table").font(.system(size: 14, weight: .black)).opacity(0.4)
        }
        .foregroundColor(.gray)
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.white.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.white.opacity(0.05), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var quickActionsGrid: some View {
        HStack(spacing: 8) {
            QuickActionButton(icon: "location.north.fill", label: "Map") { onShowOnMap(restaurant) }
            QuickActionButton(
                icon: isSaved ? "bookmark.fill" : "bookmark",
                label: isSaved ? "Saved" : "Save",
                iconColor: isSaved ? .accentSaved : .white,
                glow: isSaved ? Color.accentSaved.opacity(0.5) : .clear
            ) {
                toggleSave()
            }
            QuickActionButton(icon: "square.and.arrow.up", label: "Share") { showShareSheet = true }
            QuickActionButton(icon: "plus", label: "Log") { onLogThis() }
        }
    }

    private var cancelReservationButton: some View {
        Button(action: { withAnimation { showCancelReservation = true } }) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.minus")
                    .font(.system(size: 14)).foregroundColor(.accentUpcoming)
                    .shadow(color: Color.accentUpcoming.opacity(0.4), radius: 4)
                Text("Cancel Reservation")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(.accentUpcoming)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.accentUpcoming.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentUpcoming.opacity(0.25), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var phoneButton: some View {
        let phone = detailResponse?.restaurant?.phone ?? restaurant.phoneNumber
        return Group {
            if let phone, !phone.isEmpty {
                Button(action: {
                    let digits = phone.filter { $0.isNumber || $0 == "+" }
                    if let url = URL(string: "tel://\(digits)") { UIApplication.shared.open(url) }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 11)).foregroundColor(.accentVisited)
                            .shadow(color: Color.accentVisited.opacity(0.4), radius: 3)
                        Text(phone)
                            .font(.system(size: 13, weight: .bold)).foregroundColor(.white).tracking(0.5)
                        Spacer()
                        callBadge
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14).padding(.horizontal, 16)
                    .background(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentVisited.opacity(0.15), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private var callBadge: some View {
        Text("CALL")
            .font(.system(size: 9, weight: .bold)).foregroundColor(.accentVisited).tracking(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.accentVisited.opacity(0.1))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.accentVisited.opacity(0.3), lineWidth: 1))
    }

    private var viewAllVisitsButton: some View {
        let count = visitHistory.count
        let label = count == 1 ? "1 visit" : "\(count) visits"
        return Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showAllVisits = true }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13)).foregroundColor(.accentVisited)
                Text("View All Visits")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                Spacer()
                Text(label)
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.gray)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11)).foregroundColor(Color.gray.opacity(0.4))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.accentVisited.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentVisited.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var tabRowView: some View {
        HStack(spacing: 24) {
            tabButton(label: "About", idx: 0)
            tabButton(label: "Reviews", idx: 1)
            Spacer()
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).offset(y: 1)
        }
    }

    private func tabButton(label: String, idx: Int) -> some View {
        let isActive = activeTab == idx
        return Button(action: { withAnimation { activeTab = idx } }) {
            VStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isActive ? .white : .gray)
                Rectangle()
                    .fill(isActive ? Color.white : Color.clear)
                    .frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if activeTab == 0 {
            AboutTabView(restaurant: restaurant, detailResponse: detailResponse)
        } else {
            ReviewsTabView(restaurant: restaurant, detailResponse: detailResponse)
        }
    }

    // MARK: - Overlays
    private func toggleSave() {
        if isSaved {
            showToast("Removed from Wishlist")
            isSaved = false
            Task { await AppState.shared.removeFromWishlist(restaurant) }
        } else {
            showToast("Saved to Wishlist")
            isSaved = true
            Task { await AppState.shared.saveToWishlist(restaurant) }
        }
    }

    @ViewBuilder
    private var cancelOverlay: some View {
        if showCancelReservation {
            CancelReservationAlert(
                restaurantName: restaurant.name,
                dontRemind: $dontRemindCancel,
                onConfirm: {
                    Task {
                        await AppState.shared.deleteVisit(restaurant)
                        await MainActor.run {
                            showToast("Reservation cancelled")
                            showCancelReservation = false
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { isPresented = false }
                        }
                    }
                },
                onDismiss: { showCancelReservation = false }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .zIndex(50)
        }
    }

    @ViewBuilder
    private var allVisitsOverlay: some View {
        if showAllVisits {
            AllVisitsPane(restaurant: restaurant, isPresented: $showAllVisits)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(60)
        }
    }

    private var visitHistory: [VisitRow] {
        let dbKey = restaurant.dbId ?? restaurant.yelpId
        return appState.visitRows.filter { row in
            guard let place = row.restaurants else { return false }
            if let dbKey, place.id == dbKey || place.yelp_id == dbKey { return true }
            if place.name.lowercased() == restaurant.name.lowercased() { return true }
            return false
        }
    }

    @MainActor
    private func loadRestaurantDetail() async {
        guard let yelpId = restaurant.yelpId, !yelpId.hasPrefix("manual_") else {
            detailResponse = nil
            return
        }
        isLoadingDetail = true
        do {
            let response = try await SupabaseClient.shared.restaurantDetail(yelpId: yelpId)
            detailResponse = response
        } catch {
            print("Restaurant detail load failed: \(error)")
        }
        isLoadingDetail = false
    }
}

// MARK: - Quick Action Button
struct QuickActionButton: View {
    let icon: String
    let label: String
    var iconColor: Color = .white
    var glow: Color = .clear
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18)).foregroundColor(iconColor)
                    .shadow(color: glow, radius: 5)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.white).tracking(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .background(Color.surface.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.2), radius: 6)
        }
    }
}

// MARK: - About Tab
struct AboutTabView: View {
    let restaurant: Restaurant
    let detailResponse: RestaurantDetailResponse?

    private var cuisineTags: [String] {
        let tags = detailResponse?.restaurant?.cuisine_tags ?? restaurant.cuisineTags
        return tags.isEmpty ? [restaurant.cuisineTag] : tags
    }

    private var aboutText: String {
        if let text = detailResponse?.restaurant?.description, !text.isEmpty { return text }
        if let restaurantText = restaurant.aboutText, !restaurantText.isEmpty { return restaurantText }
        let price = detailResponse?.restaurant?.price_range ?? ""
        let cuisine = cuisineTags.joined(separator: ", ")
        let reviews = detailResponse?.restaurant?.review_count ?? restaurant.reviewCount ?? 0
        let openStatus = detailResponse?.restaurant?.is_open_now == true ? "Open now" : "Hours available"
        return [price, cuisine, reviews > 0 ? "\(reviews) Yelp reviews" : nil, openStatus].compactMap { $0 }.joined(separator: " • ")
    }

    private var yelpHours: [String: String] {
        detailResponse?.hours ?? restaurant.hours
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            aboutHours
            aboutDetails
            aboutDescription
        }
        .padding(.top, 16)
    }

    private var aboutHours: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOURS").font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(1.5)
            if yelpHours.isEmpty {
                Text("Hours not available").font(.system(size: 12)).foregroundColor(.gray)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(yelpHours.keys.sorted(), id: \.self) { key in
                        hourRow(key.capitalized, yelpHours[key] ?? "")
                    }
                }
            }
        }
    }

    private func hourRow(_ day: String, _ hours: String) -> some View {
        HStack {
            Text(day).font(.system(size: 12, weight: .medium)).foregroundColor(.gray)
            Spacer()
            Text(hours).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
        }
    }

    private var aboutDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DETAILS").font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(1.5)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if let price = detailResponse?.restaurant?.price_range, !price.isEmpty {
                        DetailPill(label: price, icon: "dollarsign.circle.fill", color: .accentVisited)
                    } else if restaurant.cuisineTag != "Restaurant" {
                        DetailPill(label: restaurant.cuisineTag, icon: "fork.knife", color: .accentVisited)
                    }
                    ForEach(cuisineTags.prefix(3), id: \.self) { tag in
                        DetailPill(label: tag.capitalized, icon: "fork.knife", color: .accentSaved)
                    }
                    if let reviewCount = detailResponse?.restaurant?.review_count ?? restaurant.reviewCount, reviewCount > 0 {
                        DetailPill(label: "\(reviewCount) Yelp reviews", icon: "star.fill", color: .orange)
                    }
                }
            }
        }
    }

    private var aboutDescription: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ABOUT").font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(1.5)
            Text(aboutText)
                .font(.system(size: 12)).foregroundColor(.gray).lineSpacing(5)
        }
    }
}

struct DetailPill: View {
    let label: String; let icon: String; let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(color)
            Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.1))
        .overlay(Capsule().stroke(color.opacity(0.2), lineWidth: 1))
        .clipShape(Capsule())
    }
}

// MARK: - Reviews Tab
struct ReviewsTabView: View {
    let restaurant: Restaurant
    let detailResponse: RestaurantDetailResponse?

    private var reviews: [YelpReview] {
        let yelp = detailResponse?.yelp_reviews ?? restaurant.yelpReviews
        return yelp.isEmpty ? fallbackReviews : yelp
    }

    private var fallbackReviews: [YelpReview] {
        [
            YelpReview(author: "Sarah M.", rating: 5, text: "Absolutely transcendent. Every course was a masterpiece.", time_created: "2 weeks ago"),
            YelpReview(author: "James K.", rating: 5, text: "The sommelier pairing was extraordinary. Warm and knowledgeable.", time_created: "1 month ago"),
            YelpReview(author: "Priya R.", rating: 4, text: "One of the best meals of my life. The dessert course surprised me.", time_created: "2 months ago"),
        ]
    }

    var body: some View {
        VStack(spacing: 14) {
            ratingHeader
            ForEach(reviews) { review in
                reviewCard(review)
            }
        }
    }

    private var ratingHeader: some View {
        HStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(String(format: "%.1f", restaurant.rating))
                    .font(.system(size: 40, weight: .black)).foregroundColor(.white)
                starRow(count: Int(restaurant.rating))
                Text("\(reviews.count) reviews").font(.system(size: 10)).foregroundColor(.gray)
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    private func starRow(count: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { i in
                Image(systemName: "star.fill").font(.system(size: 10))
                    .foregroundColor(i < count ? .accentVisited : .surfaceLight)
            }
        }
    }

    private func reviewCard(_ review: YelpReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(review.author).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                Spacer()
                starRow(count: review.rating)
                Text(review.time_created).font(.system(size: 9)).foregroundColor(.gray).padding(.leading, 4)
            }
            Text(review.text).font(.system(size: 12)).foregroundColor(.gray).lineSpacing(4)
        }
        .padding(14)
        .background(Color.surface)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.white.opacity(0.05), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - All Visits Pane
struct AllVisitsPane: View {
    let restaurant: Restaurant
    @Binding var isPresented: Bool
    @ObservedObject private var appState = AppState.shared

    private var visits: [VisitRow] {
        let dbKey = restaurant.dbId ?? restaurant.yelpId
        return appState.visitRows.filter { row in
            guard let place = row.restaurants else { return false }
            if let dbKey, place.id == dbKey || place.yelp_id == dbKey { return true }
            if place.name.lowercased() == restaurant.name.lowercased() { return true }
            return false
        }
        .sorted {
            let lhs = $0.visit_date ?? ""
            let rhs = $1.visit_date ?? ""
            return lhs > rhs
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.appBg.opacity(0.97).background(.ultraThinMaterial).ignoresSafeArea()
                VStack(spacing: 0) {
                    header(geo: geo)
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            if visits.isEmpty {
                                VStack(spacing: 10) {
                                    Spacer().frame(height: 80)
                                    Text("No visits yet")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                    Text("Your visit history will appear here once you log a meal.")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                        .multilineTextAlignment(.center)
                                    Spacer().frame(height: 80)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 32)
                            } else {
                                ForEach(visits.indices, id: \.self) { i in
                                    visitRow(i, geo: geo)
                                }
                            }
                        }
                        .padding(.leading, geo.safeAreaInsets.leading + 24)
                        .padding(.trailing, geo.safeAreaInsets.trailing + 24)
                        .padding(.top, 24).padding(.bottom, 80)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private func header(geo: GeometryProxy) -> some View {
        HStack(spacing: 14) {
            Button(action: { withAnimation { isPresented = false } }) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 32, height: 32).background(Color.white.opacity(0.1)).clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Visit History").font(.system(size: 18, weight: .black)).foregroundColor(.white)
                Text(restaurant.name).font(.system(size: 11)).foregroundColor(.gray)
            }
            Spacer()
            Text("\(visits.count) visits").font(.system(size: 11, weight: .bold)).foregroundColor(.gray)
        }
        .padding(.leading, geo.safeAreaInsets.leading + 24)
        .padding(.trailing, geo.safeAreaInsets.trailing + 24)
        .padding(.top, 56).padding(.bottom, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
    }

    private func visitRow(_ i: Int, geo: GeometryProxy) -> some View {
        let visit = visits[i]
        let isLast = i == visits.count - 1
        let dateText = formattedDate(visit.visit_date)
        let timeText = visit.visit_time ?? ""
        let notes = visit.notes ?? ""
        return HStack(alignment: .top, spacing: 16) {
            timelineSpine(isLast: isLast)
            visitCard(dateText: dateText, timeText: timeText, rating: visit.rating ?? 0, partySize: visit.party_size, notes: notes, isLast: isLast)
        }
    }

    private func formattedDate(_ string: String?) -> String {
        guard let string else { return "" }
        let inFmt = DateFormatter(); inFmt.locale = Locale(identifier: "en_US_POSIX"); inFmt.dateFormat = "yyyy-MM-dd"
        let outFmt = DateFormatter(); outFmt.dateFormat = "MMM d, yyyy"
        if let date = inFmt.date(from: string) { return outFmt.string(from: date) }
        return string
    }

    private func timelineSpine(isLast: Bool) -> some View {
        VStack(spacing: 0) {
            Circle().fill(Color.accentVisited).frame(width: 10, height: 10)
                .shadow(color: .accentVisited, radius: 4)
            if !isLast {
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).frame(maxHeight: .infinity)
            }
        }
        .padding(.top, 4)
    }

    private func visitCard(dateText: String, timeText: String, rating: Double, partySize: Int?, notes: String, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dateText).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<max(0, Int(rating.rounded())), id: \.self) { _ in
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundColor(.accentVisited)
                    }
                }
            }
            HStack(spacing: 6) {
                Text(timeText).font(.system(size: 10)).foregroundColor(.gray)
                if let partySize {
                    Text("•").foregroundColor(.gray)
                    Text("Party of \(partySize)").font(.system(size: 10)).foregroundColor(.gray)
                }
            }
            if !notes.isEmpty {
                Text(notes).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.7))
                    .lineSpacing(4).italic()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.white.opacity(0.05), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.bottom, isLast ? 0 : 16)
    }
}

// MARK: - ShareSheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
