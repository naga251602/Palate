import SwiftUI

struct LogView: View {
    var onAddLog: () -> Void
    var onSelectRestaurant: (Restaurant) -> Void
    var onViewAll: (String, RestaurantType) -> Void

    @ObservedObject private var appState = AppState.shared
    @State private var showDeleteAlert = false
    @State private var restaurantToDelete: Restaurant? = nil
    @State private var dontShowDeleteWarning = false

    var visitedRestaurants: [Restaurant] { appState.visitedRestaurants }
    var wishlistRestaurants: [Restaurant] { appState.wishlistRestaurants }
    var upcomingRestaurants: [Restaurant] { appState.upcomingRestaurants }

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
            // Pull to refresh
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 130)

                    // Stats Row
                    HStack(spacing: 8) {
                        StatCard(icon: "🌍", label: "Places", value: appState.stats.map { "\($0.total_visits)" } ?? "—", color: .accentVisited)
                        StatCard(icon: "🍴", label: "Cuisines", value: appState.stats.map { "\($0.unique_cuisines)" } ?? "—", color: .white.opacity(0.5))
                        StatCard(icon: "🛣", label: "Miles", value: appState.stats.map { $0.total_miles_traveled >= 1000 ? String(format: "%.1fk", $0.total_miles_traveled/1000) : "\(Int($0.total_miles_traveled))" } ?? "—", color: .accentUpcoming)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .task { if appState.visitedRestaurants.isEmpty { await appState.loadAll() } }

                    // Next Up Section
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(
                            title: "Next Up",
                            actionLabel: "View All (\(upcomingRestaurants.count))",
                            actionColor: .accentUpcoming
                        ) { onViewAll("Next Up", .upcoming) }
                        .padding(.horizontal, 24)

                        if let featured = upcomingRestaurants.first {
                            FeaturedUpcomingCard(restaurant: featured) {
                                onSelectRestaurant(featured)
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.bottom, 32)

                    // Recently Visited Section
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(
                            title: "Recently Visited",
                            actionLabel: "View All (\(visitedRestaurants.count))",
                            actionColor: .accentVisited
                        ) { onViewAll("Recently Visited", .visited) }
                        .padding(.horizontal, 24)

                        List {
                            ForEach(visitedRestaurants.prefix(3)) { restaurant in
                                VisitedRowCard(restaurant: restaurant) {
                                    onSelectRestaurant(restaurant)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        if dontShowDeleteWarning {
                                            Task { await appState.deleteVisit(restaurant) }
                                        } else {
                                            restaurantToDelete = restaurant
                                            showDeleteAlert = true
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash.fill")
                                    }
                                    .tint(Color.accentUpcoming)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        onSelectRestaurant(restaurant)
                                    } label: {
                                        Label("View", systemImage: "eye.fill")
                                    }
                                    .tint(Color.accentVisited)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .frame(height: CGFloat(min(visitedRestaurants.count, 3)) * 90)
                    }
                    .padding(.bottom, 32)

                    // Wishlist Section
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(
                            title: "I'd Like to Visit",
                            actionLabel: "View All (\(wishlistRestaurants.count))",
                            actionColor: .accentSaved
                        ) { onViewAll("Wishlist", .wishlist) }
                        .padding(.horizontal, 24)

                        List {
                            ForEach(wishlistRestaurants.prefix(3)) { restaurant in
                                WishlistRowCard(restaurant: restaurant) {
                                    onSelectRestaurant(restaurant)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await appState.removeFromWishlist(restaurant) }
                                    } label: {
                                        Label("Unsave", systemImage: "bookmark.slash.fill")
                                    }
                                    .tint(Color.accentSaved)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .frame(height: CGFloat(min(wishlistRestaurants.count, 3)) * 90)
                    }
                    .padding(.bottom, 120)
                }
            }
            .refreshable { await appState.loadAll() }
            .background(Color.appBg)

            // Delete confirmation alert overlay
            if showDeleteAlert, let restaurant = restaurantToDelete {
                DeleteAlertOverlay(
                    restaurantName: restaurant.name,
                    dontShowAgain: $dontShowDeleteWarning,
                    onDelete: {
                        Task { await appState.deleteVisit(restaurant) }
                        restaurantToDelete = nil
                        showDeleteAlert = false
                    },
                    onCancel: {
                        restaurantToDelete = nil
                        showDeleteAlert = false
                    }
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDeleteAlert)
    }
}

// MARK: - Delete Alert Overlay
struct DeleteAlertOverlay: View {
    let restaurantName: String
    @Binding var dontShowAgain: Bool
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var localDontShow = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 0) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.accentUpcoming.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "trash.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.accentUpcoming)
                        .shadow(color: Color.accentUpcoming.opacity(0.4), radius: 8)
                }
                .padding(.top, 28)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)

                Text("Delete Visit?")
                    .font(.system(size: 18, weight: .black))
                    .foregroundColor(.white)
                    .tracking(-0.3)
                    .padding(.bottom, 8)

                Text("This will permanently delete **\(restaurantName)** along with all timeline data, visit notes, and ratings.")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)

                // Don't show again toggle
                Button(action: {
                    withAnimation { localDontShow.toggle() }
                }) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(localDontShow ? Color.accentUpcoming : Color.white.opacity(0.08))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .stroke(localDontShow ? Color.accentUpcoming : Color.white.opacity(0.15), lineWidth: 1)
                                )
                            if localDontShow {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        Text("Don't show this warning again")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.6))
                    }
                }
                .padding(.bottom, 20)

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                // Action buttons
                HStack(spacing: 0) {
                    // Cancel
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 1)

                    // Delete
                    Button(action: {
                        dontShowAgain = localDontShow
                        onDelete()
                    }) {
                        Text("Delete")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.accentUpcoming)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color.black.opacity(0.5), radius: 40)
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Stat Card
struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Text(icon).font(.system(size: 22)).opacity(0.2)
            }
            .padding(.bottom, 4)

            Text(value)
                .font(.system(size: 28, weight: .black))
                .foregroundColor(.white)
                .tracking(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
                .tracking(1.2)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(
            ZStack {
                Color.surface
                LinearGradient(
                    colors: [color.opacity(0.12), Color.clear],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: color.opacity(0.15), radius: 10)
    }
}

// MARK: - Section Header
struct SectionHeader: View {
    let title: String
    let actionLabel: String
    let actionColor: Color
    let action: () -> Void

    var body: some View {
        HStack(alignment: .bottom) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            Button(action: action) {
                Text(actionLabel.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(actionColor)
                    .tracking(0.5)
            }
        }
    }
}

// MARK: - Featured Upcoming Card
struct FeaturedUpcomingCard: View {
    let restaurant: Restaurant
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    AsyncImage(url: URL(string: restaurant.imageURL)) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { Color.surfaceLight }
                    .frame(height: 160).clipped()

                    LinearGradient(colors: [Color.clear, Color.surface.opacity(0.8)], startPoint: .top, endPoint: .bottom)

                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(.accentVisited)
                            .shadow(color: Color.accentVisited.opacity(0.5), radius: 4)
                        Text(String(format: "%.1f", restaurant.rating)).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(14)

                    HStack(spacing: 6) {
                        Circle().fill(Color.accentUpcoming).frame(width: 8, height: 8).shadow(color: Color.accentUpcoming, radius: 4)
                        Text("In 2 Days").font(.system(size: 9, weight: .bold)).foregroundColor(.white).tracking(0.5)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.6)).clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14)
                }
                .frame(height: 160).clipped()

                VStack(alignment: .leading, spacing: 0) {
                    Text(restaurant.name).font(.system(size: 22, weight: .black)).foregroundColor(.white).tracking(-0.5).padding(.bottom, 2)
                    Text(restaurant.location).font(.system(size: 11, weight: .medium)).foregroundColor(.gray).padding(.bottom, 16)
                    HStack(spacing: 8) {
                        MiniStatPill(label: "DATE", value: "May 17")
                        MiniStatPill(label: "TIME", value: "8:30 PM")
                        MiniStatPill(label: "PARTY", value: "2")
                    }
                }
                .padding(20).padding(.top, 0)
            }
        }
        .background(ZStack { Color.surface; LinearGradient(colors: [Color.surface, Color.appBg], startPoint: .top, endPoint: .bottom) })
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.05), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.3), radius: 20)
        .overlay(
            RadialGradient(colors: [Color.accentUpcoming.opacity(0.15), Color.clear], center: .topTrailing, startRadius: 0, endRadius: 80)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)).allowsHitTesting(false)
        )
    }
}

struct MiniStatPill: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundColor(.gray).tracking(1)
            Text(value).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color.surfaceLight)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.05), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Visited Row Card
struct VisitedRowCard: View {
    let restaurant: Restaurant
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AsyncImage(url: URL(string: restaurant.imageURL)) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.surfaceLight }
                .frame(width: 56, height: 56).clipShape(Circle())
                .overlay(Circle().stroke(Color.accentVisited, lineWidth: 2))
                .shadow(color: Color.accentVisited.opacity(0.3), radius: 6)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(restaurant.name).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        Spacer()
                        Text(restaurant.visitDate.isEmpty ? "Apr 22" : String(restaurant.visitDate.prefix(6)))
                            .font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(0.3)
                    }
                    Text(restaurant.location).font(.system(size: 10)).foregroundColor(.gray).lineLimit(1).padding(.bottom, 2)
                    HStack(spacing: 2) {
                        ForEach(0..<5) { i in
                            Image(systemName: i < Int(restaurant.rating) ? "star.fill" : "star.leadinghalf.filled")
                                .font(.system(size: 8)).foregroundColor(.accentVisited)
                                .shadow(color: Color.accentVisited.opacity(0.5), radius: 2)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.surface.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.05), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 8)
        }
    }
}

// MARK: - Wishlist Row Card
struct WishlistRowCard: View {
    let restaurant: Restaurant
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AsyncImage(url: URL(string: restaurant.imageURL)) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.surfaceLight }
                .frame(width: 56, height: 56).clipShape(Circle())
                .overlay(Circle().stroke(Color.accentSaved, lineWidth: 2))
                .shadow(color: Color.accentSaved.opacity(0.3), radius: 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(restaurant.name).font(.system(size: 14, weight: .bold)).foregroundColor(.white).padding(.bottom, 1)
                    Text(restaurant.location).font(.system(size: 10)).foregroundColor(.gray).lineLimit(1).padding(.bottom, 3)
                    HStack(spacing: 4) {
                        Image(systemName: "camera.fill").font(.system(size: 9)).foregroundColor(.accentSaved)
                            .shadow(color: Color.accentSaved.opacity(0.5), radius: 3)
                        Text(restaurant.savedFromLabel).font(.system(size: 9)).italic().foregroundColor(.gray)
                    }
                }
                Spacer()
            }
            .padding(14)
            .background(Color.surface.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.05), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 8)
        }
    }
}
