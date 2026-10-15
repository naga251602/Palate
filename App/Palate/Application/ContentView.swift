import SwiftUI

struct ContentView: View {
    @State private var isAuthenticated = SupabaseClient.shared.isAuthenticated
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var selectedTab: AppTab = .map

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            if isAuthenticated {
                MainTabView(selectedTab: $selectedTab, showToast: showToast(message:))
            }

            if !isAuthenticated {
                AuthView(onAuthenticated: { displayName in
                    withAnimation(.easeInOut(duration: 0.4)) { isAuthenticated = true }
                    showToast(message: "Welcome, \(displayName) 👋")
                })
                .transition(.opacity)
                .zIndex(100)
            }

            VStack {
                if showToast {
                    ToastView(message: toastMessage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 56)
            .zIndex(200)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showToast)
        }
        .onReceive(NotificationCenter.default.publisher(for: .signOut)) { _ in
            withAnimation { isAuthenticated = false }
        }
    }

    func showToast(message: String) {
        toastMessage = message
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { showToast = false }
        }
    }
}

extension Notification.Name {
    static let signOut = Notification.Name("palate.signOut")
    static let openNotificationsPanel = Notification.Name("palate.openNotificationsPanel")
}

enum AppTab: String, CaseIterable {
    case map = "map", log = "log", profile = "profile"
    var icon: String {
        switch self { case .map: return "map.fill"; case .log: return "book.fill"; case .profile: return "person.fill" }
    }
    var label: String {
        switch self { case .map: return "Map"; case .log: return "Log"; case .profile: return "Profile" }
    }
}
