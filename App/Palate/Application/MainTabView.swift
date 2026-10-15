// this file consist of the code to control main navigation of the app

import SwiftUI

struct MainTabView: View {
    @Binding var selectedTab: AppTab
    var showToast: (String) -> Void

    @ObservedObject private var appState = AppState.shared
    @StateObject private var routeCoordinator = RouteCoordinator()
    @State private var showNotifications = false
    @State private var activeContactPane: ContactPaneType? = nil
    @State private var contactPaneBinding: Binding<[ContactItem]>? = nil
    @State private var showAddLog = false
    @State private var showRestaurantDetail = false
    @State private var showViewAll = false
    @State private var selectedRestaurant: Restaurant? = nil
    @State private var logPrefillRestaurant: Restaurant? = nil
    @State private var viewAllTitle = ""
    @State private var viewAllType: RestaurantType = .visited

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                MapView(
                    showToast: showToast,
                    onSelectRestaurant: { restaurant in
                        selectedRestaurant = restaurant
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            showRestaurantDetail = true
                        }
                    },
                    routeCoordinator: routeCoordinator
                )
                .opacity(selectedTab == .map ? 1 : 0)
                .allowsHitTesting(selectedTab == .map)

                LogView(
                    onAddLog: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showAddLog = true }
                    },
                    onSelectRestaurant: { restaurant in
                        selectedRestaurant = restaurant
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            showRestaurantDetail = true
                        }
                    },
                    onViewAll: { title, type in
                        viewAllTitle = title
                        viewAllType = type
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            showViewAll = true
                        }
                    }
                )
                .opacity(selectedTab == .log ? 1 : 0)
                .allowsHitTesting(selectedTab == .log)

                ProfileView(
                    onSignOut: {},
                    onOpenContactPane: { paneType, binding in
                        activeContactPane = paneType
                        contactPaneBinding = binding
                    }
                )
                .opacity(selectedTab == .profile ? 1 : 0)
                .allowsHitTesting(selectedTab == .profile)
            }
            .ignoresSafeArea()

            // Header
            VStack {
                AppHeaderView(
                    unreadCount: appState.notifications.filter { !$0.isRead }.count,
                    onNotificationTap: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            showNotifications = true
                        }
                    }
                )
                Spacer()
            }
            .ignoresSafeArea(edges: .top)
            .zIndex(40)

            // FAB
            FABView(selectedTab: selectedTab) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showAddLog = true }
            }
            .zIndex(30)

            BottomNavBar(selectedTab: $selectedTab)
                .zIndex(90)
        }
        .overlay(overlayNotifications)
        .overlay(overlayRestaurantDetail)
        .overlay(overlayAddLog)
        .overlay(overlayViewAll)
        .task {
            if appState.visitedRestaurants.isEmpty && appState.wishlistRestaurants.isEmpty && appState.stats == nil {
                await appState.loadAll()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showNotifications)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showRestaurantDetail)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showAddLog)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showViewAll)
        .overlay(overlayContactPane)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: activeContactPane != nil)
        .onReceive(NotificationCenter.default.publisher(for: .openNotificationsPanel)) { _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                showNotifications = true
            }
        }
    }

    // MARK: - Overlays
    @ViewBuilder
    private var overlayNotifications: some View {
        if showNotifications {
            NotificationsOverlay(isPresented: $showNotifications)
                .transition(.move(edge: .bottom))
                .zIndex(85)
        }
    }

    @ViewBuilder
    private var overlayRestaurantDetail: some View {
        if let restaurant = selectedRestaurant, showRestaurantDetail {
            RestaurantDetailOverlay(
                restaurant: restaurant,
                isPresented: $showRestaurantDetail,
                showToast: showToast,
                onLogThis: {
                    logPrefillRestaurant = selectedRestaurant
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        showRestaurantDetail = false
                        showAddLog = true
                    }
                },
                onShowOnMap: { restaurant in
                    // 1. Close the detail pane
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        showRestaurantDetail = false
                    }
                    // 2. Switch to map tab
                    withAnimation { selectedTab = .map }
                    // 3. Fire route after brief delay so MapView is visible
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        routeCoordinator.requestRoute(to: restaurant)
                    }
                }
            )
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
            .zIndex(80)
        }
    }

    @ViewBuilder
    private var overlayAddLog: some View {
        if showAddLog {
            AddLogOverlay(
                isPresented: $showAddLog,
                showToast: showToast,
                prefillRestaurant: logPrefillRestaurant
            )
            .transition(.move(edge: .bottom))
            .zIndex(85)
            .onDisappear { logPrefillRestaurant = nil }
        }
    }

    @ViewBuilder
    private var overlayViewAll: some View {
        if showViewAll {
            ViewAllOverlay(
                isPresented: $showViewAll,
                title: viewAllTitle,
                type: viewAllType,
                onSelectRestaurant: { restaurant in
                    selectedRestaurant = restaurant
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        showViewAll = false
                        showRestaurantDetail = true
                    }
                }
            )
            .transition(.move(edge: .bottom))
            .zIndex(70)
        }
    }

    @ViewBuilder
    private var overlayContactPane: some View {
        if let paneType = activeContactPane, let binding = contactPaneBinding {
            ContactPaneOverlay(
                type: paneType,
                items: binding,
                isPresented: Binding(
                    get: { activeContactPane != nil },
                    set: { if !$0 { activeContactPane = nil; contactPaneBinding = nil } }
                )
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(95)
        }
    }
}

// MARK: - FAB
struct FABView: View {
    let selectedTab: AppTab
    let action: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if selectedTab == .log {
                    FABLabel()
                        .onTapGesture { action() }
                        .transition(.scale.combined(with: .opacity))
                        .padding(.trailing, 24)
                        .padding(.bottom, 100)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selectedTab)
    }
}

struct FABLabel: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 22, weight: .black))
            .foregroundColor(Color.appBg)
            .frame(width: 56, height: 56)
            .background(Color.white)
            .clipShape(Circle())
            .shadow(color: Color.white.opacity(0.4), radius: 20)
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 2))
    }
}

// MARK: - App Header
struct AppHeaderView: View {
    var unreadCount: Int = 0
    var onNotificationTap: () -> Void
    @ObservedObject private var appState = AppState.shared

    private var greetingName: String {
        if let name = appState.profileRow?.display_name, !name.isEmpty { return name.uppercased() }
        if let username = appState.profileRow?.username, !username.isEmpty { return username.uppercased() }
        if let email = SupabaseClient.shared.currentUserEmail {
            return (email.components(separatedBy: "@").first ?? "there").uppercased()
        }
        return "THERE"
    }

    private var timeOfDay: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return "GOOD MORNING"
        case 12..<17: return "GOOD AFTERNOON"
        default:      return "GOOD EVENING"
        }
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Palate.")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(LinearGradient(
                        colors: [.white, Color.white.opacity(0.6)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .tracking(-0.5)
                Text("\(timeOfDay), \(greetingName)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.7))
                    .tracking(2)
            }
            Spacer()
            Button(action: onNotificationTap) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: unreadCount > 0 ? "bell.badge" : "bell")
                        .font(.system(size: 16)).foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.surface.opacity(0.6))
                        .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.3), radius: 8)
                    if unreadCount > 0 {
                        Text(unreadCount > 9 ? "9+" : "\(unreadCount)")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(Color.appBg)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentUpcoming)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.appBg.opacity(0.3), lineWidth: 1))
                            .offset(x: -2, y: 2)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 64)
        .padding(.bottom, 16)
        .background(LinearGradient(
            stops: [
                .init(color: Color.appBg, location: 0),
                .init(color: Color.appBg.opacity(0.8), location: 0.7),
                .init(color: Color.appBg.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        ))
    }
}

// MARK: - Bottom Nav
struct BottomNavBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button(action: { withAnimation { selectedTab = tab } }) {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 20, weight: .semibold))
                        Text(tab.label).font(.system(size: 9, weight: .bold)).tracking(1.5)
                    }
                    .foregroundColor(selectedTab == tab ? .white : Color.gray)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(
            ZStack {
                Color.surface.opacity(0.9)
                Color.black.opacity(0.5)
            }
            .background(.ultraThinMaterial)
            .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
        .shadow(color: Color.black.opacity(0.5), radius: 20, y: -10)
    }
}

// MARK: - Toast
struct ToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.accentVisited)
                .shadow(color: Color.accentVisited.opacity(0.5), radius: 4)
            Text(message).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.surface.opacity(0.9))
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.4), radius: 20)
    }
}
