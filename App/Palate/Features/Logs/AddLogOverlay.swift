import SwiftUI
import EventKit
import MapKit

struct AddLogOverlay: View {
    @Binding var isPresented: Bool
    var showToast: (String) -> Void
    var prefillRestaurant: Restaurant? = nil

    @State private var searchText = ""
    @State private var selectedRestaurant: Restaurant? = nil
    @State private var selectedMapPlace: MapPlace? = nil   // real MK result
    @State private var showResults = false
    @State private var mkResults: [MapPlace] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var isLoggingIn = false

    @State private var partySize = ""
    @State private var rating = 0
    @State private var logDate = Date()
    @State private var logTime = Date()

    // Treat the entry as upcoming only if it is clearly in the future.
    // A small grace window prevents "current timestamp" logs from being misclassified.
    var dateIsFuture: Bool {
        combinedDate().timeIntervalSinceNow > 60
    }

    var resolvedName: String {
        selectedMapPlace?.name ?? selectedRestaurant?.name ?? ""
    }
    var resolvedAddress: String {
        selectedMapPlace?.address ?? selectedRestaurant?.location ?? ""
    }
    var hasSelection: Bool { selectedMapPlace != nil || selectedRestaurant != nil }

    var body: some View {
        ZStack {
            Color.appBg.opacity(0.95).background(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Log Entry")
                        .font(.system(size: 22, weight: .black)).foregroundColor(.white).tracking(-0.5)
                    Spacer()
                    Button(action: { withAnimation { isPresented = false } }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                            .frame(width: 32, height: 32).background(Color.white.opacity(0.1)).clipShape(Circle())
                    }
                }
                .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 16)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {

                        // ── Restaurant Search ──
                        if !hasSelection {
                            VStack(spacing: 0) {
                                HStack(spacing: 12) {
                                    Image(systemName: isSearching ? "arrow.trianglehead.2.clockwise" : "magnifyingglass")
                                        .font(.system(size: 14)).foregroundColor(.gray)
                                    TextField("Search restaurant name...", text: $searchText)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white).tint(.white)
                                        .autocapitalization(.none).disableAutocorrection(true)
                                        .onChange(of: searchText) { _, val in searchRestaurants(val) }
                                    if !searchText.isEmpty {
                                        Button(action: { searchText = ""; mkResults = []; showResults = false }) {
                                            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.gray)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 16)
                                .background(Color.surface.opacity(0.6))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                                // Results dropdown
                                if showResults && !mkResults.isEmpty {
                                    VStack(spacing: 0) {
                                        ForEach(mkResults) { place in
                                            Button(action: {
                                                selectedMapPlace = place
                                                searchText = ""
                                                showResults = false
                                            }) {
                                                HStack(spacing: 12) {
                                                    ZStack {
                                                        Circle().fill(Color.accentVisited.opacity(0.1)).frame(width: 40, height: 40)
                                                        Image(systemName: "fork.knife")
                                                            .font(.system(size: 14)).foregroundColor(.accentVisited)
                                                    }
                                                    VStack(alignment: .leading, spacing: 3) {
                                                        Text(place.name)
                                                            .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                                                        Text(place.address)
                                                            .font(.system(size: 10)).foregroundColor(.gray).lineLimit(1)
                                                    }
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 14).padding(.vertical, 12)
                                            }
                                            if place.id != mkResults.last?.id {
                                                Divider().background(Color.white.opacity(0.05))
                                            }
                                        }
                                    }
                                    .background(Color.surface)
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.05), lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .shadow(color: Color.black.opacity(0.4), radius: 20)
                                    .padding(.top, 8)
                                }
                            }
                        }

                        // ── Selected card ──
                        if hasSelection {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().fill(Color.accentVisited.opacity(0.1)).frame(width: 56, height: 56)
                                    Image(systemName: "fork.knife")
                                        .font(.system(size: 22)).foregroundColor(.accentVisited)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(resolvedName)
                                        .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                    Text(resolvedAddress)
                                        .font(.system(size: 10)).foregroundColor(.gray).lineLimit(1)
                                }
                                Spacer()
                                Button(action: { selectedMapPlace = nil; selectedRestaurant = nil }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12)).foregroundColor(.gray)
                                        .frame(width: 30, height: 30).background(Color.white.opacity(0.05)).clipShape(Circle())
                                }
                            }
                            .padding(14)
                            .background(Color.surface.opacity(0.6))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.accentVisited.opacity(0.2), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }

                        // ── Date & Time ──
                        HStack(spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar").font(.system(size: 14)).foregroundColor(.gray)
                                DatePicker("", selection: $logDate, displayedComponents: .date)
                                    .labelsHidden().tint(.accentVisited).colorScheme(.dark)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 14).frame(maxWidth: .infinity)
                            .background(Color.surface.opacity(0.6))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            HStack(spacing: 10) {
                                Image(systemName: "clock").font(.system(size: 14)).foregroundColor(.gray)
                                DatePicker("", selection: $logTime, displayedComponents: .hourAndMinute)
                                    .labelsHidden().tint(.accentVisited).colorScheme(.dark)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 14).frame(maxWidth: .infinity)
                            .background(Color.surface.opacity(0.6))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        // ── Party size ──
                        HStack(spacing: 12) {
                            Image(systemName: "person.2.fill").font(.system(size: 14)).foregroundColor(.gray)
                            TextField("Party size (e.g. 2)", text: $partySize)
                                .font(.system(size: 14, weight: .medium)).foregroundColor(.white).tint(.white)
                                .keyboardType(.numberPad)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 16)
                        .background(Color.surface.opacity(0.6))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        // ── Star Rating ──
                        VStack(spacing: 10) {
                            Text("YOUR RATING")
                                .font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(1.5)
                            HStack(spacing: 14) {
                                ForEach(1...5, id: \.self) { star in
                                    Button(action: {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { rating = star }
                                    }) {
                                        Image(systemName: "star.fill").font(.system(size: 26))
                                            .foregroundColor(rating >= star ? .accentVisited : .surfaceLight)
                                            .shadow(color: rating >= star ? Color.accentVisited.opacity(0.5) : .clear, radius: 6)
                                            .scaleEffect(rating == star ? 1.15 : 1.0)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                        .background(LinearGradient(colors: [Color.surface, Color.appBg], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.05), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        // ── Save buttons ──
                        VStack(spacing: 12) {
                            Button(action: saveLog) {
                                Text("Save Entry")
                                    .font(.system(size: 14, weight: .black)).foregroundColor(Color.appBg)
                                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .shadow(color: Color.white.opacity(0.2), radius: 16)
                            }

                            // Only show "Add to Calendar" when date is in the future
                            if dateIsFuture {
                                Button(action: saveLogAndAddToCalendar) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "calendar.badge.plus").font(.system(size: 14))
                                            .foregroundColor(.accentUpcoming)
                                            .shadow(color: Color.accentUpcoming.opacity(0.5), radius: 4)
                                        Text("Save & Add to Calendar")
                                            .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dateIsFuture)
                    }
                    .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 80)
                }
            }
        }
        .onAppear {
            if let r = prefillRestaurant {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedRestaurant = r
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasSelection)
    }

    // MARK: - Real restaurant search via MKLocalSearch
    func searchRestaurants(_ query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            mkResults = []; showResults = false; isSearching = false; return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [
                .restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket, .nightlife
            ])
            if let response = try? await MKLocalSearch(request: request).start() {
                let places = response.mapItems.prefix(8).map { MapPlace(mapItem: $0) }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    mkResults = Array(places)
                    showResults = true
                    isSearching = false
                }
            } else {
                await MainActor.run { isSearching = false }
            }
        }
    }

    func combinedDate() -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: logDate)
        let t = Calendar.current.dateComponents([.hour, .minute], from: logTime)
        c.hour = t.hour ?? 19; c.minute = t.minute ?? 0
        return Calendar.current.date(from: c) ?? logDate
    }

    func saveLog() {
        guard !resolvedName.isEmpty else {
            showToast("Please select a restaurant")
            return
        }
        isLoggingIn = true
        Task {
            do {
                let restaurantToPersist: Restaurant
                if let selectedRestaurant {
                    restaurantToPersist = selectedRestaurant
                } else if let place = selectedMapPlace {
                    restaurantToPersist = Restaurant(
                        dbId: nil,
                        yelpId: syntheticRestaurantId(name: place.name, latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
                        savedFrom: "map",
                        name: place.name,
                        location: place.address,
                        imageURL: "https://images.unsplash.com/photo-1550966871-3ed3cdb5ed0c?q=80&w=800&auto=format&fit=crop",
                        types: [.wishlist],
                        rating: 4.5,
                        lat: place.coordinate.latitude,
                        lng: place.coordinate.longitude,
                        visitDate: "",
                        visitDateGroup: ""
                    )
                } else {
                    throw PalateError.notFound
                }

                let restaurantId = try await SupabaseClient.shared.ensureRestaurantId(for: restaurantToPersist)

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let dateStr = formatter.string(from: logDate)
                formatter.dateFormat = "HH:mm"
                let timeStr = formatter.string(from: logTime)

                let visitType = dateIsFuture ? "upcoming" : "visited"
                let req = LogVisitRequest(
                    restaurantId: restaurantId,
                    visitType: visitType,
                    visitDate: dateStr,
                    visitTime: timeStr,
                    partySize: Int(partySize) ?? 2,
                    rating: Double(rating),
                    notes: "",
                    dishes: []
                )
                let resp = try await SupabaseClient.shared.logVisit(req)
                await AppState.shared.loadAll()

                // Schedule reminder if upcoming
                if visitType == "upcoming" {
                    NotificationManager.shared.scheduleReservationReminder(
                        restaurantName: resolvedName,
                        date: combinedDate(),
                        hoursBeforehand: 3
                    )
                    try? await SupabaseClient.shared.scheduleReminder(
                        reservationId: resp.visit_id,
                        restaurantName: resolvedName,
                        datetime: combinedDate()
                    )
                }

                await MainActor.run {
                    isLoggingIn = false
                    withAnimation { isPresented = false }
                    let milestone = resp.milestone.map { " 🎉 Milestone: \($0)" } ?? ""
                    showToast("Logged Successfully\(milestone)")
                }
            } catch {
                await MainActor.run {
                    isLoggingIn = false
                    showToast("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    func saveLogAndAddToCalendar() {
        let store = EKEventStore()
        // Explicitly ask for permission with explanatory prompt
        store.requestFullAccessToEvents { granted, error in
            DispatchQueue.main.async {
                guard granted else { showToast("Calendar access denied"); return }
                let event = EKEvent(eventStore: store)
                event.title = "Dinner at \(resolvedName)"
                event.location = resolvedAddress
                event.notes = "Party of \(partySize.isEmpty ? "2" : partySize)"
                let startDate = combinedDate()
                event.startDate = startDate
                event.endDate = startDate.addingTimeInterval(7200)
                event.calendar = store.defaultCalendarForNewEvents
                do {
                    try store.save(event, span: .thisEvent)
                    withAnimation { isPresented = false }
                    showToast("Saved & Added to Calendar ✓")
                } catch {
                    showToast("Could not save to Calendar")
                }
            }
        }
    }
}
