import SwiftUI

// MARK: - Contact Item Models
struct ContactItem: Identifiable {
    var id: String = UUID().uuidString
    var value: String
    var isPrimary: Bool = false
}

enum ContactPaneType {
    case email, instagram, phone

    var title: String {
        switch self {
        case .email:     return "Email Addresses"
        case .instagram: return "Instagram Accounts"
        case .phone:     return "Phone Numbers"
        }
    }
    var icon: String {
        switch self {
        case .email:     return "envelope.fill"
        case .instagram: return "camera.fill"
        case .phone:     return "phone.fill"
        }
    }
    var color: Color {
        switch self {
        case .email:     return .accentVisited
        case .instagram: return .accentSaved
        case .phone:     return Color.purple
        }
    }
    var placeholder: String {
        switch self {
        case .email:     return "Enter email address"
        case .instagram: return "Enter @username"
        case .phone:     return "Enter phone number"
        }
    }
    var keyboard: UIKeyboardType {
        switch self {
        case .email:     return .emailAddress
        case .instagram: return .default
        case .phone:     return .phonePad
        }
    }

    var apiValue: String {
        switch self {
        case .email: return "email"
        case .instagram: return "instagram"
        case .phone: return "phone"
        }
    }
}

// MARK: - Profile View
struct ProfileView: View {
    var onSignOut: () -> Void
    var onOpenContactPane: (ContactPaneType, Binding<[ContactItem]>) -> Void = { _, _ in }

    @ObservedObject private var appState = AppState.shared

    @State private var showDeleteAccountAlert = false
    @State private var stats: UserStats? = nil
    @State private var totalVisits: String = "—"
    @State private var totalCuisines: String = "—"
    @State private var totalMiles: String = "—"

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 130)

                    // Avatar + name
                    VStack(spacing: 16) {
                        ZStack(alignment: .bottomTrailing) {
                            AsyncImage(url: URL(string: "https://images.unsplash.com/photo-1535713875002-d1d0cf377fde?q=80&w=200&auto=format&fit=crop")) { img in
                                img.resizable().scaledToFill()
                            } placeholder: { Color.surfaceLight }
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.surfaceLight, lineWidth: 3))
                            .shadow(color: Color.black.opacity(0.4), radius: 16)

                            Text("PRO")
                                .font(.system(size: 9, weight: .black)).foregroundColor(Color.appBg)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.appBg, lineWidth: 1))
                        }

                        Text(displayNameText)
                            .font(.system(size: 26, weight: .black)).foregroundColor(.white).tracking(-0.5)

                        HStack(spacing: 16) {
                            StatBadge(icon: "location.fill", color: .accentVisited, count: appState.stats.map { "\($0.total_visits)" } ?? "—", label: "Visited")
                            StatBadge(icon: "bookmark.fill", color: .accentSaved, count: "\(appState.wishlistRestaurants.count)", label: "Saved")
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.bottom, 32)

                    // Contact cards
                    VStack(spacing: 8) {
                        ContactRowCard(
                            type: .email,
                            items: appState.emailContacts,
                            onTap: { onOpenContactPane(.email, contactBinding(\.emailContacts)) }
                        )
                        ContactRowCard(
                            type: .instagram,
                            items: appState.instagramContacts,
                            onTap: { onOpenContactPane(.instagram, contactBinding(\.instagramContacts)) }
                        )
                        ContactRowCard(
                            type: .phone,
                            items: appState.phoneContacts,
                            onTap: { onOpenContactPane(.phone, contactBinding(\.phoneContacts)) }
                        )
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)

                    // Sign Out
                    Button(action: handleSignOut) {
                        Text("Sign Out")
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.accentUpcoming)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                            .background(Color.surface.opacity(0.5))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.accentUpcoming.opacity(0.3), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                    // Delete Account
                    Button(action: { showDeleteAccountAlert = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 12)).foregroundColor(Color.red.opacity(0.8))
                            Text("Delete Account")
                                .font(.system(size: 14, weight: .bold)).foregroundColor(Color.red.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(Color.red.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.red.opacity(0.2), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 120)
                }
            }
            .background(Color.appBg)

            // Delete account alert
            if showDeleteAccountAlert {
                DeleteAccountAlert(
                    onConfirm: {
                        showDeleteAccountAlert = false
                        onSignOut()
                    },
                    onDismiss: { showDeleteAccountAlert = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(60)
            }
        }
        .task {
            if appState.stats == nil || appState.profileRow == nil || appState.emailContacts.isEmpty && appState.instagramContacts.isEmpty && appState.phoneContacts.isEmpty {
                await appState.loadAll()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showDeleteAccountAlert)
    }

    private var displayNameText: String {
        if let name = appState.profileRow?.display_name, !name.isEmpty { return name }
        if let username = appState.profileRow?.username, !username.isEmpty { return username }
        if let email = SupabaseClient.shared.currentUserEmail {
            return email.components(separatedBy: "@").first?.capitalized ?? "Alex Foodie"
        }
        return "Alex Foodie"
    }

    private func contactBinding(_ keyPath: ReferenceWritableKeyPath<AppState, [ContactItem]>) -> Binding<[ContactItem]> {
        Binding(
            get: { appState[keyPath: keyPath] },
            set: { appState[keyPath: keyPath] = $0 }
        )
    }

    func loadStats() async {
        do {
            let s = try await SupabaseClient.shared.fetchStats()
            await MainActor.run {
                totalVisits = "\(s.total_visits)"
                totalCuisines = "\(s.unique_cuisines)"
                let miles = s.total_miles_traveled
                totalMiles = miles >= 1000 ? String(format: "%.1fk", miles / 1000) : "\(Int(miles))"
            }
        } catch { print("Stats load failed: \(error)") }
    }

    func handleSignOut() {
        SupabaseClient.shared.signOut()
        NotificationCenter.default.post(name: .signOut, object: nil)
        onSignOut()
    }
}

// MARK: - Contact Row Card (summary view)
struct ContactRowCard: View {
    let type: ContactPaneType
    let items: [ContactItem]
    let onTap: () -> Void

    var primaryValue: String {
        items.first(where: { $0.isPrimary })?.value ?? items.first?.value ?? "Not set"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                Image(systemName: type.icon)
                    .font(.system(size: 13))
                    .foregroundColor(type.color)
                    .shadow(color: type.color.opacity(0.4), radius: 4)
                    .frame(width: 36, height: 36)
                    .background(type.color.opacity(0.1))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(type.title)
                        .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                    Text(primaryValue)
                        .font(.system(size: 10)).foregroundColor(.gray).lineLimit(1)
                }

                Spacer()

                if items.count > 1 {
                    Text("+\(items.count - 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(type.color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(type.color.opacity(0.1))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(type.color.opacity(0.2), lineWidth: 1))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12)).foregroundColor(Color.gray.opacity(0.4))
            }
            .padding(16)
            .background(Color.surface)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.black.opacity(0.2), radius: 6)
        }
    }
}

// MARK: - Contact Pane Overlay (CRUD sheet)
struct ContactPaneOverlay: View {
    let type: ContactPaneType
    @Binding var items: [ContactItem]
    @Binding var isPresented: Bool

    @State private var newValue = ""
    @State private var isAdding = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.appBg.opacity(0.97).background(.ultraThinMaterial).ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(type.color.opacity(0.12)).frame(width: 40, height: 40)
                            Image(systemName: type.icon)
                                .font(.system(size: 15)).foregroundColor(type.color)
                                .shadow(color: type.color.opacity(0.4), radius: 4)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.title)
                                .font(.system(size: 18, weight: .black)).foregroundColor(.white).tracking(-0.3)
                            Text("\(items.count) saved")
                                .font(.system(size: 10)).foregroundColor(.gray)
                        }

                        Spacer()

                        Button(action: { withAnimation { isPresented = false } }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.1)).clipShape(Circle())
                        }
                    }
                    .padding(.leading, geo.safeAreaInsets.leading + 24)
                    .padding(.trailing, geo.safeAreaInsets.trailing + 24)
                    .padding(.top, 56).padding(.bottom, 16)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                    }

                    // Add new field
                    if isAdding {
                        HStack(spacing: 12) {
                            Image(systemName: type.icon)
                                .font(.system(size: 13)).foregroundColor(type.color)

                            TextField(type.placeholder, text: $newValue)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white).tint(.white)
                                .keyboardType(type.keyboard)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .focused($fieldFocused)

                            Button(action: addItem) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(type.color)
                                    .frame(width: 32, height: 32)
                                    .background(type.color.opacity(0.12)).clipShape(Circle())
                            }
                            .disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                            .opacity(newValue.isEmpty ? 0.4 : 1)

                            Button(action: { isAdding = false; newValue = "" }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.gray)
                                    .frame(width: 32, height: 32)
                                    .background(Color.white.opacity(0.06)).clipShape(Circle())
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .background(type.color.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(type.color.opacity(0.25), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, geo.safeAreaInsets.leading + 24)
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear { fieldFocused = true }
                    }

                    // Items list
                    List {
                        ForEach($items) { $item in
                            ContactItemRow(
                                item: $item,
                                type: type,
                                onSetPrimary: { setPrimary(item.id) },
                                onDelete: { deleteItem(item.id) },
                                onCommitEdit: { persistItems() }
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: geo.safeAreaInsets.leading + 24, bottom: 6, trailing: geo.safeAreaInsets.trailing + 24))
                            .buttonStyle(.plain)
                        }

                        // Add button row
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isAdding = true
                            }
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(type.color)
                                    .frame(width: 36, height: 36)
                                    .background(type.color.opacity(0.1)).clipShape(Circle())

                                Text("Add \(type.title.components(separatedBy: " ").last ?? "")")
                                    .font(.system(size: 13, weight: .bold)).foregroundColor(type.color)

                                Spacer()
                            }
                            .padding(14)
                            .background(type.color.opacity(0.05))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(type.color.opacity(0.15), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: geo.safeAreaInsets.leading + 24, bottom: 6, trailing: geo.safeAreaInsets.trailing + 24))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .padding(.top, isAdding ? 8 : 16)
                    .safeAreaInset(edge: .bottom) {
                        Spacer().frame(height: 100)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isAdding)
    }

    func addItem() {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            items.append(ContactItem(value: trimmed, isPrimary: items.isEmpty))
            newValue = ""
            isAdding = false
        }
        persistItems()
    }

    func deleteItem(_ id: String) {
        withAnimation { items.removeAll { $0.id == id } }
        if !items.contains(where: { $0.isPrimary }), let firstIndex = items.indices.first {
            items[firstIndex].isPrimary = true
        }
        persistItems()
    }

    func setPrimary(_ id: String) {
        withAnimation {
            for i in items.indices { items[i].isPrimary = items[i].id == id }
        }
        persistItems()
    }

    private func persistItems() {
        Task { await AppState.shared.saveContactItems(type: type.apiValue, items: items) }
    }
}

// MARK: - Contact Item Row
struct ContactItemRow: View {
    @Binding var item: ContactItem
    let type: ContactPaneType
    let onSetPrimary: () -> Void
    let onDelete: () -> Void
    let onCommitEdit: () -> Void

    @State private var isEditing = false
    @State private var editValue = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Primary indicator / set primary button
            Button(action: onSetPrimary) {
                ZStack {
                    Circle()
                        .fill(item.isPrimary ? type.color.opacity(0.15) : Color.white.opacity(0.05))
                        .frame(width: 36, height: 36)
                    if item.isPrimary {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14)).foregroundColor(type.color)
                            .shadow(color: type.color.opacity(0.4), radius: 4)
                    } else {
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
                            .frame(width: 16, height: 16)
                    }
                }
            }

            // Value (editable)
            if isEditing {
                TextField("", text: $editValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white).tint(.white)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { commitEdit() }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.value)
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    if item.isPrimary {
                        Text("PRIMARY")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(type.color).tracking(1.5)
                    }
                }
            }

            Spacer()

            // Edit / confirm button
            Button(action: {
                if isEditing { commitEdit() }
                else { editValue = item.value; isEditing = true }
            }) {
                Image(systemName: isEditing ? "checkmark" : "pencil")
                    .font(.system(size: 12))
                    .foregroundColor(isEditing ? type.color : Color.gray.opacity(0.5))
                    .frame(width: 30, height: 30)
                    .background(isEditing ? type.color.opacity(0.1) : Color.white.opacity(0.04))
                    .clipShape(Circle())
            }

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color.accentUpcoming.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.accentUpcoming.opacity(0.08)).clipShape(Circle())
            }
        }
        .padding(14)
        .background(Color.surface)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(item.isPrimary ? type.color.opacity(0.2) : Color.white.opacity(0.05), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.2), radius: 6)
        .contentShape(Rectangle())
    }

    func commitEdit() {
        let trimmed = editValue.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { item.value = trimmed }
        isEditing = false
        onCommitEdit()
    }
}

// MARK: - Delete Account Alert
struct DeleteAccountAlert: View {
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    @State private var confirmText = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea().onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.12)).frame(width: 64, height: 64)
                    Image(systemName: "person.crop.circle.badge.minus")
                        .font(.system(size: 26)).foregroundColor(.red)
                        .shadow(color: Color.red.opacity(0.4), radius: 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28).padding(.bottom, 16)

                Text("Delete Account?")
                    .font(.system(size: 18, weight: .black)).foregroundColor(.white).tracking(-0.3).padding(.bottom, 8)

                Text("This will permanently delete your account, all visit logs, timeline data, and preferences. This cannot be undone.")
                    .font(.system(size: 13)).foregroundColor(.gray)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .padding(.horizontal, 24).padding(.bottom, 16)

                // Confirm typing
                TextField("Type DELETE to confirm", text: $confirmText)
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.white).tint(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24).padding(.bottom, 20)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                HStack(spacing: 0) {
                    Button(action: onDismiss) {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                    Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                    Button(action: { if confirmText == "DELETE" { onConfirm() } }) {
                        Text("Delete")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(confirmText == "DELETE" ? .red : Color.gray.opacity(0.4))
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                    .disabled(confirmText != "DELETE")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.surface)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color.black.opacity(0.5), radius: 40)
            .padding(.horizontal, 28)
        }
    }
}

// MARK: - Reused StatBadge
struct StatBadge: View {
    let icon: String
    let color: Color
    let count: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(color)
                .shadow(color: color.opacity(0.5), radius: 4)
            Text("\(count) \(label)").font(.system(size: 10, weight: .bold)).foregroundColor(.white).tracking(0.5)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .clipShape(Capsule())
    }
}
