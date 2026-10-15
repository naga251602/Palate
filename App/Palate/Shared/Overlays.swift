import SwiftUI

// MARK: - View All Overlay
struct ViewAllOverlay: View {
    @Binding var isPresented: Bool
    let title: String
    let type: RestaurantType
    var onSelectRestaurant: (Restaurant) -> Void

    @ObservedObject private var appState = AppState.shared
    @State private var items: [Restaurant] = []
    @State private var showCancelAlert = false
    @State private var restaurantToCancel: Restaurant? = nil
    @State private var dontRemindCancel = false
    @State private var filterFrom: Date = Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? Date()
    @State private var filterTo: Date = Date()

    var filteredItems: [Restaurant] {
        guard type == .visited else { return items }
        return items.filter { r in
            guard !r.visitDate.isEmpty else { return true }
            let fmt = DateFormatter(); fmt.dateFormat = "MMM dd, yyyy"
            guard let d = fmt.date(from: r.visitDate) else { return true }
            return d >= filterFrom && d <= filterTo
        }
    }

    var groupedByDate: [(String, [Restaurant])] {
        guard type == .visited else { return [] }
        var groups: [(String, [Restaurant])] = []
        var seen: [String] = []
        for r in items {
            let key = r.visitDateGroup.isEmpty ? "Other" : r.visitDateGroup
            if !seen.contains(key) { seen.append(key); groups.append((key, [])) }
            if let idx = groups.firstIndex(where: { $0.0 == key }) { groups[idx].1.append(r) }
        }
        return groups
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.appBg.opacity(0.95).background(.ultraThinMaterial).ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 14) {
                        Button(action: { withAnimation { isPresented = false } }) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                        Text(title)
                            .font(.system(size: 18, weight: .black))
                            .foregroundColor(.white)
                            .tracking(-0.3)
                        Spacer()
                        Text("\(filteredItems.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.gray)
                    }
                    .padding(.leading, geo.safeAreaInsets.leading + 24)
                    .padding(.trailing, geo.safeAreaInsets.trailing + 24)
                    .padding(.top, 56)
                    .padding(.bottom, type == .visited ? 8 : 16)

                    // Date picker filter for visited
                    if type == .visited {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar").font(.system(size: 12)).foregroundColor(.gray)
                            DatePicker("From", selection: $filterFrom, displayedComponents: .date)
                                .labelsHidden().tint(.accentVisited).colorScheme(.dark).scaleEffect(0.9)
                            Text("→").font(.system(size: 12)).foregroundColor(.gray)
                            DatePicker("To", selection: $filterTo, displayedComponents: .date)
                                .labelsHidden().tint(.accentVisited).colorScheme(.dark).scaleEffect(0.9)
                            Spacer()
                            Button(action: { filterFrom = Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? Date(); filterTo = Date() }) {
                                Text("Reset").font(.system(size: 10, weight: .bold)).foregroundColor(.accentVisited)
                            }
                        }
                        .padding(.horizontal, geo.safeAreaInsets.leading + 24)
                        .padding(.vertical, 10)
                    }

                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)

                    // List with swipe actions
                    List {
                        if type == .visited {
                            ForEach(groupedByDate, id: \.0) { group, groupItems in
                                Section {
                                    ForEach(filteredItems.filter { groupItems.map(\.id).contains($0.id) }) { restaurant in
                                        ViewAllRow(restaurant: restaurant) { onSelectRestaurant(restaurant) }
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(EdgeInsets(top: 4, leading: geo.safeAreaInsets.leading + 24, bottom: 4, trailing: geo.safeAreaInsets.trailing + 24))
                                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                                Button(role: .destructive) {
                                                    Task {
                                                        await AppState.shared.deleteVisit(restaurant)
                                                        await MainActor.run {
                                                            withAnimation { items.removeAll { $0.id == restaurant.id } }
                                                        }
                                                    }
                                                } label: { Label("Delete", systemImage: "trash.fill") }
                                                .tint(Color.accentUpcoming)
                                            }
                                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                                Button { onSelectRestaurant(restaurant) } label: { Label("View", systemImage: "eye.fill") }
                                                    .tint(Color.accentVisited)
                                            }
                                    }
                                } header: {
                                    HStack(spacing: 8) {
                                        Text(group.uppercased())
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.gray)
                                            .tracking(1.5)
                                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                                    }
                                    .listRowInsets(EdgeInsets(top: 12, leading: geo.safeAreaInsets.leading + 24, bottom: 6, trailing: geo.safeAreaInsets.trailing + 24))
                                }
                            }
                        } else {
                            ForEach(items) { restaurant in
                                ViewAllRow(restaurant: restaurant) { onSelectRestaurant(restaurant) }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 4, leading: geo.safeAreaInsets.leading + 24, bottom: 4, trailing: geo.safeAreaInsets.trailing + 24))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: type == .wishlist) {
                                        if type == .wishlist {
                                            Button(role: .destructive) {
                                                Task { await AppState.shared.removeFromWishlist(restaurant) }
                                                withAnimation { items.removeAll { $0.id == restaurant.id } }
                                            } label: { Label("Unsave", systemImage: "bookmark.slash.fill") }
                                            .tint(Color.accentSaved)
                                        } else if type == .upcoming {
                                            Button {
                                                restaurantToCancel = restaurant
                                                showCancelAlert = true
                                            } label: { Label("Cancel", systemImage: "xmark.circle.fill") }
                                            .tint(Color.accentUpcoming)
                                        }
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button { onSelectRestaurant(restaurant) } label: { Label("View", systemImage: "eye.fill") }
                                            .tint(Color.accentVisited)
                                    }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }

                // Cancel reservation alert
                if showCancelAlert, let r = restaurantToCancel {
                    CancelReservationAlert(
                        restaurantName: r.name,
                        dontRemind: $dontRemindCancel,
                        onConfirm: {
                            Task {
                                await AppState.shared.deleteVisit(r)
                                await MainActor.run {
                                    withAnimation { items.removeAll { $0.id == r.id } }
                                    restaurantToCancel = nil
                                    showCancelAlert = false
                                }
                            }
                        },
                        onDismiss: {
                            restaurantToCancel = nil
                            showCancelAlert = false
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(50)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { syncItems() }
        .onReceive(appState.$visitedRestaurants) { _ in syncItems() }
        .onReceive(appState.$upcomingRestaurants) { _ in syncItems() }
        .onReceive(appState.$wishlistRestaurants) { _ in syncItems() }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showCancelAlert)
    }

    private func syncItems() {
        switch type {
        case .visited:  items = appState.visitedRestaurants
        case .upcoming: items = appState.upcomingRestaurants
        case .wishlist: items = appState.wishlistRestaurants
        }
    }
}

// MARK: - Cancel Reservation Alert
struct CancelReservationAlert: View {
    let restaurantName: String
    @Binding var dontRemind: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    @State private var localDontRemind = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea().onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // Icon
                ZStack {
                    Circle().fill(Color.accentUpcoming.opacity(0.15)).frame(width: 64, height: 64)
                    Image(systemName: "calendar.badge.minus")
                        .font(.system(size: 26)).foregroundColor(.accentUpcoming)
                        .shadow(color: Color.accentUpcoming.opacity(0.4), radius: 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28).padding(.bottom, 16)

                Text("Cancel Reservation?")
                    .font(.system(size: 18, weight: .black))
                    .foregroundColor(.white).tracking(-0.3).padding(.bottom, 8)

                Text("Are you sure you want to cancel your reservation at **\(restaurantName)**? This action cannot be undone.")
                    .font(.system(size: 13)).foregroundColor(.gray)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .padding(.horizontal, 24).padding(.bottom, 20)

                // Don't remind toggle
                Button(action: { withAnimation { localDontRemind.toggle() } }) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(localDontRemind ? Color.accentUpcoming : Color.white.opacity(0.08))
                                .frame(width: 20, height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(localDontRemind ? Color.accentUpcoming : Color.white.opacity(0.15), lineWidth: 1))
                            if localDontRemind {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                            }
                        }
                        Text("Don't remind me again")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.6))
                    }
                }
                .padding(.bottom, 20)

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                // Buttons
                HStack(spacing: 0) {
                    Button(action: onDismiss) {
                        Text("Keep it")
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                    Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                    Button(action: {
                        dontRemind = localDontRemind
                        onConfirm()
                    }) {
                        Text("Cancel It")
                            .font(.system(size: 15, weight: .bold)).foregroundColor(.accentUpcoming)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.surface)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color.black.opacity(0.5), radius: 40)
            .padding(.horizontal, 32)
        }
    }
}


struct ViewAllRow: View {
    let restaurant: Restaurant
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: restaurant.imageURL)) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.surfaceLight }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(Circle().stroke(restaurant.primaryType.color, lineWidth: 2))

                VStack(alignment: .leading, spacing: 3) {
                    Text(restaurant.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    if !restaurant.visitDate.isEmpty {
                        Text(restaurant.visitDate)
                            .font(.system(size: 10))
                            .foregroundColor(restaurant.primaryType.color.opacity(0.8))
                    } else {
                        Text(restaurant.location)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !restaurant.visitDate.isEmpty && restaurant.primaryType == .visited {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.accentVisited)
                        Text(String(format: "%.1f", restaurant.rating))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentVisited.opacity(0.1))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.accentVisited.opacity(0.2), lineWidth: 1))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(Color.gray.opacity(0.4))
            }
            .padding(12)
            .background(Color.surface.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.2), radius: 6)
        }
    }
}


// MARK: - Notifications Overlay
struct NotificationsOverlay: View {
    @Binding var isPresented: Bool
    @ObservedObject private var appState = AppState.shared

    private func icon(for type: String) -> String {
        switch type.lowercased() {
        case "email_import":         return "envelope.fill"
        case "email_import_failed":  return "envelope.badge.shield.half.filled"
        case "new_visit":            return "clock.fill"
        case "new_wishlist":         return "bookmark.fill"
        case "milestone":            return "flame.fill"
        case "reservation_reminder": return "calendar.badge.clock"
        default:                     return "bell.fill"
        }
    }

    private func color(for type: String) -> Color {
        switch type.lowercased() {
        case "email_import":         return .accentUpcoming
        case "email_import_failed":  return Color.orange
        case "new_visit":            return .accentVisited
        case "new_wishlist":         return .accentSaved
        case "milestone":            return .orange
        case "reservation_reminder": return .accentUpcoming
        default:                     return .gray
        }
    }

    private var unreadCount: Int { appState.notifications.filter { !$0.isRead }.count }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.appBg.opacity(0.95).background(.ultraThinMaterial).ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications")
                                .font(.system(size: 18, weight: .black))
                                .foregroundColor(.white)
                                .tracking(-0.3)
                            if unreadCount > 0 {
                                Text("\(unreadCount) unread")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.accentUpcoming)
                            }
                        }
                        Spacer()
                        // Mark all read
                        if unreadCount > 0 {
                            Button(action: {
                                Task { await appState.clearNotifications() }
                            }) {
                                Text("Mark All Read")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.accentUpcoming)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.accentUpcoming.opacity(0.1))
                                    .overlay(Capsule().stroke(Color.accentUpcoming.opacity(0.3), lineWidth: 1))
                                    .clipShape(Capsule())
                            }
                            .padding(.trailing, 8)
                        }
                        // Close
                        Button(action: { withAnimation { isPresented = false } }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.leading, geo.safeAreaInsets.leading + 24)
                    .padding(.trailing, geo.safeAreaInsets.trailing + 24)
                    .padding(.top, 56)
                    .padding(.bottom, 16)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                    }

                    if appState.notifications.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "bell.slash")
                                .font(.system(size: 36))
                                .foregroundColor(Color.gray.opacity(0.3))
                            Text("No notifications")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Color.gray.opacity(0.4))
                            Text("Reservation confirmations and\nmilestones will appear here.")
                                .font(.system(size: 11))
                                .foregroundColor(Color.gray.opacity(0.3))
                                .multilineTextAlignment(.center)
                            Spacer()
                        }
                    } else {
                        List {
                            ForEach(appState.notifications) { notif in
                                NotificationItemRow(
                                    item: notif,
                                    iconName: icon(for: notif.type),
                                    tint: color(for: notif.type)
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(
                                    top: 4,
                                    leading: geo.safeAreaInsets.leading + 24,
                                    bottom: 4,
                                    trailing: geo.safeAreaInsets.trailing + 24
                                ))
                                // Swipe LEFT → mark read
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    if !notif.isRead {
                                        Button {
                                            Task { await appState.markNotificationRead(notificationId: notif.id) }
                                        } label: {
                                            Label("Read", systemImage: "checkmark.circle.fill")
                                        }
                                        .tint(Color.accentVisited)
                                    }
                                }
                                // Swipe RIGHT → delete
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await appState.deleteNotification(notificationId: notif.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash.fill")
                                    }
                                    .tint(Color.accentUpcoming)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .padding(.top, 8)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .task { await appState.refreshNotifications() }
    }
}

// MARK: - Notification Item Row
struct NotificationItemRow: View {
    let item: AppNotificationItem
    let iconName: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Icon / logo
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(tint.opacity(item.isRead ? 0.08 : 0.15)).frame(width: 44, height: 44)
                    if let logoURL = item.logoURL, let url = URL(string: logoURL) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: iconName)
                                .font(.system(size: 16))
                                .foregroundColor(tint.opacity(item.isRead ? 0.5 : 1))
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: iconName)
                            .font(.system(size: 16))
                            .foregroundColor(tint.opacity(item.isRead ? 0.5 : 1))
                            .shadow(color: item.isRead ? .clear : tint.opacity(0.4), radius: 4)
                    }
                }
                .frame(width: 44, height: 44)

                // Unread dot
                if !item.isRead {
                    Circle()
                        .fill(Color.accentUpcoming)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.appBg, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }

            // Text
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: item.isRead ? .semibold : .bold))
                    .foregroundColor(item.isRead ? Color.white.opacity(0.6) : .white)
                    .lineLimit(1)
                Text(item.message)
                    .font(.system(size: 11))
                    .foregroundColor(Color.gray.opacity(item.isRead ? 0.5 : 0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(item.time)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.gray.opacity(0.5))
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(item.isRead ? Color.surface.opacity(0.3) : Color.surface.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(item.isRead ? Color.white.opacity(0.04) : Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
