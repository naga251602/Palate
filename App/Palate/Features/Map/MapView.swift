import SwiftUI
import MapKit
import CoreLocation

// MARK: - Nearby Place
struct NearbyPlace: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    let category: String // "restaurant", "cafe", "food"
    var icon: String {
        switch category {
        case "cafe": return "cup.and.saucer.fill"
        case "bar":  return "wineglass.fill"
        default:     return "fork.knife"
        }
    }
    var color: Color {
        switch category {
        case "cafe": return Color(hex: "#F59E0B")
        case "bar":  return Color(hex: "#A78BFA")
        default:     return Color(hex: "#6B7280")
        }
    }
}

// MARK: - Static Home Pin (small white dot + pulse rings)
struct StaticHomePinView: View {
    @State private var p1 = false
    @State private var p2 = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(p1 ? 0 : 0.5), lineWidth: 1.5)
                .scaleEffect(p1 ? 2.0 : 1.0).frame(width: 28, height: 28)
            Circle().stroke(Color.white.opacity(p2 ? 0 : 0.35), lineWidth: 1)
                .scaleEffect(p2 ? 1.6 : 1.0).frame(width: 24, height: 24)
            Circle().fill(Color.white).frame(width: 12, height: 12)
                .shadow(color: Color.white.opacity(0.9), radius: 6)
        }
        .frame(width: 60, height: 60)
        .onAppear {
            withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) { p1 = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) { p2 = true }
            }
        }
    }
}

struct HomePinView: View {
    var body: some View { StaticHomePinView() }
}

struct MapView: View {
    var showToast: (String) -> Void
    var onSelectRestaurant: (Restaurant) -> Void
    @ObservedObject var routeCoordinator: RouteCoordinator

    @StateObject private var navManager = NavigationManager()

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
        )
    )
    @State private var activeFilter: RestaurantType = .visited
    @State private var searchText = ""
    @State private var searchResults: [Restaurant] = []
    @State private var showSearchResults = false
    @State private var routeDestination: Restaurant? = nil
    @State private var computedRoute: MKRoute? = nil
    @State private var isComputingRoute = false
    @State private var showRoutePane = false
    @State private var selectedAnnotation: Restaurant? = nil
    @State private var chipColorsActive = false
    @State private var nearbyPOIs: [NearbyPlace] = []
    @State private var showNearby = false
    @State private var showUserLocation = false
    @State private var isZoomedIn = false  // toggles between street and neighborhood
    @State private var showCitySearch = false
    @State private var recentSearches: [String] = ["Ramen near me", "Best sushi LA", "Italian downtown"]
    // Real MKLocalSearch results
    @State private var mapSearchResults: [MapPlace] = []
    @State private var showMapSearchResults = false
    @State private var selectedMapPlace: MapPlace? = nil
    @State private var showMapPlaceDetail = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var searchFocused: Bool

    static let home = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)

    var allDBRestaurants: [Restaurant] {
        AppState.shared.visitedRestaurants + AppState.shared.upcomingRestaurants + AppState.shared.wishlistRestaurants
    }
    var filteredPins: [Restaurant] {
        allDBRestaurants.filter { $0.types.contains(activeFilter) }
    }

    var body: some View {
        ZStack {
            // ── Dark street map (standard + dark color scheme) ──
            Map(position: $cameraPosition) {
                // Static home pin always visible
                Annotation("", coordinate: Self.home) {
                    StaticHomePinView()
                }

                // Real GPS blue dot - shows when location available
                if LocationManager.shared.userLocation != nil {
                    UserAnnotation()
                }

                ForEach(allDBRestaurants) { restaurant in
                    // During navigation: only show the destination pin
                    // Otherwise: show all filtered pins
                    let isDestination = routeDestination?.id == restaurant.id || navManager.isNavigating && routeDestination?.id == restaurant.id
                    let shouldShow = navManager.isNavigating ? isDestination : filteredPins.contains(where: { $0.id == restaurant.id })
                    if shouldShow {
                        Annotation("",
                                   coordinate: CLLocationCoordinate2D(latitude: restaurant.lat,
                                                                       longitude: restaurant.lng)) {
                            EnhancedPinView(
                                restaurant: restaurant,
                                isSelected: selectedAnnotation?.id == restaurant.id,
                                activeFilter: activeFilter,
                                showColors: chipColorsActive
                            )
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedAnnotation = restaurant
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    onSelectRestaurant(restaurant)
                                }
                            }
                        }
                    }
                }

                // Nearby POI pins
                if showNearby && !navManager.isNavigating {
                    ForEach(nearbyPOIs) { poi in
                        Annotation("", coordinate: poi.coordinate) {
                            NearbyPinView(place: poi)
                                .onTapGesture {
                                        // Build restaurant from nearby POI
                                    let mockImages = [
                                        "https://images.unsplash.com/photo-1550966871-3ed3cdb5ed0c?q=80&w=800&auto=format&fit=crop",
                                        "https://images.unsplash.com/photo-1414235077428-338989a2e8c0?q=80&w=800&auto=format&fit=crop",
                                        "https://images.unsplash.com/photo-1504674900247-0877df9cc836?q=80&w=800&auto=format&fit=crop",
                                        "https://images.unsplash.com/photo-1579684947550-22e945225d9a?q=80&w=800&auto=format&fit=crop",
                                    ]
                                    let img = mockImages[abs(poi.name.hashValue) % mockImages.count]
                                    let restaurant = Restaurant(
                                        savedFrom: "map",
                                        name: poi.name,
                                        location: poi.coordinate.latitude != 0 ? "Nearby" : "Los Angeles, CA",
                                        imageURL: img,
                                        types: [.wishlist],
                                        rating: 4.2,
                                        lat: poi.coordinate.latitude,
                                        lng: poi.coordinate.longitude,
                                        visitDate: "",
                                        visitDateGroup: ""
                                    )
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        cameraPosition = .region(MKCoordinateRegion(
                                            center: poi.coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                                        ))
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        onSelectRestaurant(restaurant)
                                    }
                                }
                        }
                    }
                }

                // Pin for selected search result
                if let place = selectedMapPlace {
                    Annotation("", coordinate: place.coordinate) {
                        SearchResultPinView(place: place)
                    }
                }

                if let route = computedRoute {
                    MapPolyline(route.polyline)
                        .stroke(Color.accentSaved, lineWidth: 3)
                }
            }
            // Standard street map with dark elevation
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .colorScheme(.dark)
            .mapControls {
                MapCompass()
                    .mapControlVisibility(.visible)
            }
            .ignoresSafeArea()
            .onTapGesture {
                searchFocused = false
                if searchText.isEmpty { showMapSearchResults = false }
            }

            // Vignette overlay — cinematic dark edges
            ZStack {
                // Corner vignette
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.clear, location: 0.4),
                        .init(color: Color.appBg.opacity(0.55), location: 1.0)
                    ]),
                    center: .center, startRadius: 50, endRadius: 400
                )
                // Bottom fade into app bg
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [Color.clear, Color.appBg.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 180)
                }
                // Top fade
                VStack {
                    LinearGradient(
                        colors: [Color.appBg.opacity(0.5), Color.clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 120)
                    Spacer()
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // ── TOP HUD ──
            VStack(spacing: 10) {
                Spacer().frame(height: 120)

                if !navManager.isNavigating {
                    // Search bar
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14)).foregroundColor(.gray)
                            TextField("Search restaurants...", text: $searchText)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white).tint(.white)
                                .focused($searchFocused)
                                .onChange(of: searchText) { _, val in handleRealSearch(val) }
                            if !searchText.isEmpty {
                                Button(action: { searchText = ""; showMapSearchResults = false; searchFocused = false }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14)).foregroundColor(.gray)
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .background(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Color.black.opacity(0.4), radius: 16)

                        // Recent searches when focused + empty
                        if searchFocused && searchText.isEmpty && !recentSearches.isEmpty {
                            VStack(spacing: 0) {
                                HStack {
                                    Text("RECENT").font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(1.5)
                                    Spacer()
                                    Button(action: { recentSearches.removeAll() }) {
                                        Text("Clear All").font(.system(size: 10, weight: .bold)).foregroundColor(.accentUpcoming)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)

                                ForEach(recentSearches.prefix(5), id: \.self) { search in
                                    HStack(spacing: 10) {
                                        Image(systemName: "clock").font(.system(size: 12)).foregroundColor(.gray)
                                        Button(action: {
                                            searchText = search
                                            handleRealSearch(search)
                                        }) {
                                            Text(search).font(.system(size: 13)).foregroundColor(.white).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        Button(action: { recentSearches.removeAll { $0 == search } }) {
                                            Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.gray)
                                        }
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                            }
                            .background(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Color.black.opacity(0.4), radius: 16)
                            .padding(.top, 8)
                        }

                        // Search results dropdown
                        if isSearching {
                            HStack {
                                ProgressView().tint(.white).scaleEffect(0.7)
                                Text("Searching...").font(.system(size: 12)).foregroundColor(.gray)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.top, 6)
                        } else if showMapSearchResults && !mapSearchResults.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(mapSearchResults) { place in
                                    Button(action: {
                                        searchText = ""; showMapSearchResults = false; searchFocused = false
                                        let restaurant = makeRestaurant(from: place)
                                        withAnimation {
                                            cameraPosition = .region(MKCoordinateRegion(
                                                center: place.coordinate,
                                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                                            ))
                                        }
                                        selectedMapPlace = place
                                        recentSearches.insert(place.name, at: 0)
                                        if recentSearches.count > 10 { recentSearches = Array(recentSearches.prefix(10)) }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                            onSelectRestaurant(restaurant)
                                        }
                                    }) {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Circle().fill(Color.accentVisited.opacity(0.12)).frame(width: 36, height: 36)
                                                Image(systemName: "fork.knife")
                                                    .font(.system(size: 14)).foregroundColor(.accentVisited)
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(place.name).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                                                Text(place.address).font(.system(size: 10)).foregroundColor(.gray).lineLimit(1)
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                    }
                                    if place.id != mapSearchResults.last?.id {
                                        Divider().background(Color.white.opacity(0.05))
                                    }
                                }
                            }
                            .background(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Color.black.opacity(0.5), radius: 20)
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 24)

                    // ALL chips in one single horizontal scroll row
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // Filter chips
                            ForEach(RestaurantType.allCases, id: \.self) { type in
                                FilterChip(
                                    label: type.label,
                                    icon: type.chipIcon,
                                    isActive: activeFilter == type,
                                    color: type.color
                                ) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        if activeFilter == type {
                                            chipColorsActive.toggle()
                                        } else {
                                            activeFilter = type
                                            chipColorsActive = true
                                        }
                                    }
                                }
                            }

                            // Divider
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 1, height: 22)
                                .padding(.horizontal, 2)

                            // Nearby chip
                            Button(action: {
                                withAnimation { showNearby.toggle() }
                                if showNearby && nearbyPOIs.isEmpty { fetchNearby() }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: showNearby ? "mappin.and.ellipse" : "mappin.slash")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("Nearby")
                                        .font(.system(size: 10, weight: .bold)).tracking(0.6)
                                }
                                .foregroundColor(showNearby ? Color(hex: "#F59E0B") : Color.white.opacity(0.7))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(showNearby ? Color(hex: "#F59E0B").opacity(0.18) : Color.black.opacity(0.4))
                                .background(.ultraThinMaterial)
                                .overlay(Capsule().stroke(showNearby ? Color(hex: "#F59E0B").opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1))
                                .clipShape(Capsule())
                                .shadow(color: showNearby ? Color(hex: "#F59E0B").opacity(0.3) : .clear, radius: 8)
                            }
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: showNearby)


                            // Find in city chip
                            Button(action: { showCitySearch = true }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "building.2.fill").font(.system(size: 11, weight: .semibold))
                                    Text("Find in City").font(.system(size: 10, weight: .bold)).tracking(0.6)
                                }
                                .foregroundColor(Color.white.opacity(0.7))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.black.opacity(0.4)).background(.ultraThinMaterial)
                                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                // Nav step banner
                if navManager.isNavigating {
                    NavigationStepBanner(navManager: navManager)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()
            }

            // ── BOTTOM: location button + panes ──
            VStack(spacing: 0) {
                Spacer()

                // Location button always above panes
                HStack {
                    Spacer()
                    Button(action: locateMe) {
                        Image(systemName: isZoomedIn ? "location.magnifyingglass" : (showUserLocation ? "location.fill" : "location.north.fill"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(showUserLocation ? Color.accentSaved : Color.appBg)
                            .frame(width: 50, height: 50)
                            .background(Color.white)
                            .clipShape(Circle())
                            .shadow(color: Color.white.opacity(0.5), radius: 16)
                            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1.5))
                    }
                    .padding(.trailing, 24)
                }
                .padding(.bottom, 12)

                if navManager.isNavigating {
                    NavigationBottomBar(navManager: navManager, onStop: {
                        withAnimation {
                            navManager.stopNavigation()
                            computedRoute = nil
                            routeDestination = nil
                        }
                    })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if showRoutePane, let dest = routeDestination {
                    RoutePaneView(
                        destinationName: dest.name,
                        route: computedRoute,
                        isLoading: isComputingRoute,
                        onClose: {
                            withAnimation {
                                showRoutePane = false
                                computedRoute = nil
                                routeDestination = nil
                            }
                        },
                        onNavigate: {
                            if let route = computedRoute, let dest = routeDestination {
                                withAnimation { showRoutePane = false }
                                navManager.startNavigation(route: route, destination: dest)
                                cameraPosition = .region(MKCoordinateRegion(
                                    center: Self.home,
                                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                                ))
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Spacer().frame(height: 110)
                }
            }

            // ── Map stats overlay (bottom-left, non-interactive) ──
            if !navManager.isNavigating && !showRoutePane {
                VStack {
                    Spacer()
                    HStack {
                        MapStatsChip(count: filteredPins.count, type: activeFilter, chipColorsActive: chipColorsActive)
                            .animation(.spring(response: 0.3), value: filteredPins.count)
                            .padding(.leading, 24)
                            .padding(.bottom, 120)
                        Spacer()
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showRoutePane)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: computedRoute != nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: navManager.isNavigating)
        .onAppear { fetchNearby() }
        .sheet(isPresented: $showCitySearch) {
            CitySearchView(onSearch: { city in
                showCitySearch = false
                searchText = city
                handleRealSearch(city)
                recentSearches.insert(city, at: 0)
                if recentSearches.count > 10 { recentSearches = Array(recentSearches.prefix(10)) }
            })
        }
        .onChange(of: routeCoordinator.pendingRestaurant?.id) { _, newID in
            guard newID != nil, let restaurant = routeCoordinator.consume() else { return }
            startRoute(to: restaurant)
        }
    }

    // MARK: - Routing
    private func startRoute(to restaurant: Restaurant) {
        routeDestination = restaurant
        computedRoute = nil
        isComputingRoute = true
        withAnimation { showRoutePane = true }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: Self.home))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: restaurant.lat, longitude: restaurant.lng)
        ))
        request.transportType = .automobile

        Task {
            do {
                let response = try await MKDirections(request: request).calculate()
                if let route = response.routes.first {
                    await MainActor.run {
                        computedRoute = route
                        isComputingRoute = false
                        let rect = route.polyline.boundingMapRect
                        cameraPosition = .rect(rect.insetBy(dx: -rect.size.width * 0.25,
                                                             dy: -rect.size.height * 0.25))
                    }
                }
            } catch {
                await MainActor.run {
                    isComputingRoute = false
                    showToast("Could not get directions")
                }
            }
        }
    }

    func handleSearch(_ query: String) {
        // Legacy - no longer used
    }

    // Convert a real MKLocalSearch result to a Restaurant for the detail pane
    func makeRestaurant(from place: MapPlace) -> Restaurant {
        // Pick a random food image from our pool
        let mockImages = [
            "https://images.unsplash.com/photo-1550966871-3ed3cdb5ed0c?q=80&w=800&auto=format&fit=crop",
            "https://images.unsplash.com/photo-1414235077428-338989a2e8c0?q=80&w=800&auto=format&fit=crop",
            "https://images.unsplash.com/photo-1504674900247-0877df9cc836?q=80&w=800&auto=format&fit=crop",
            "https://images.unsplash.com/photo-1555396273-367ea4eb4db5?q=80&w=800&auto=format&fit=crop",
            "https://images.unsplash.com/photo-1579684947550-22e945225d9a?q=80&w=800&auto=format&fit=crop",
            "https://images.unsplash.com/photo-1559339352-11d035aa65de?q=80&w=800&auto=format&fit=crop",
        ]
        let img = mockImages[abs(place.name.hashValue) % mockImages.count]
        return Restaurant(
            dbId: nil,
            yelpId: syntheticRestaurantId(name: place.name, latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
            savedFrom: "map",
            name: place.name,
            location: place.address,
            imageURL: img,
            types: [.wishlist],
            rating: 4.5,
            lat: place.coordinate.latitude,
            lng: place.coordinate.longitude,
            visitDate: "",
            visitDateGroup: ""
        )
    }

    func handleRealSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            mapSearchResults = []; showMapSearchResults = false; isSearching = false; return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000) // 400ms debounce
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [
                .restaurant, .cafe, .bakery, .brewery, .winery,
                .foodMarket, .nightlife
            ])
            request.region = MKCoordinateRegion(
                center: Self.home,
                span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
            )
            if let response = try? await MKLocalSearch(request: request).start() {
                let places = response.mapItems.prefix(10).map { MapPlace(mapItem: $0) }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    mapSearchResults = places
                    showMapSearchResults = true
                    isSearching = false
                }
            } else {
                await MainActor.run { isSearching = false }
            }
        }
    }

    func fetchNearby() {
        let searches = [
            ("restaurants near me", "restaurant")
        ]
        nearbyPOIs = []
        for (query, category) in searches {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(
                center: Self.home,
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )
            Task {
                if let response = try? await MKLocalSearch(request: request).start() {
                    let places = response.mapItems.prefix(6).map { item in
                        NearbyPlace(
                            name: item.name ?? "Unknown",
                            coordinate: item.placemark.coordinate,
                            category: category
                        )
                    }
                    await MainActor.run {
                        nearbyPOIs.append(contentsOf: places)
                    }
                }
            }
        }
    }

    func locateMe() {
        let mgr = CLLocationManager()
        mgr.requestWhenInUseAuthorization()
        let coord = mgr.location?.coordinate ?? Self.home
        showUserLocation = true

        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            if isZoomedIn {
                // Zoom out to neighborhood
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06)
                ))
                isZoomedIn = false
            } else {
                // Zoom into street level
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                ))
                isZoomedIn = true
            }
        }
    }
}

// MARK: - Single radar pulse ring (animation-based, CPU-friendly)
struct PulseRing: View {
    let color: Color
    let delay: Double
    @State private var animating = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .scaleEffect(animating ? 1.9 : 1.0)
            .opacity(animating ? 0 : 0.7)
            .frame(width: 48, height: 48)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
                        animating = true
                    }
                }
            }
    }
}

// MARK: - Enhanced Pin with radar pulse
struct EnhancedPinView: View {
    let restaurant: Restaurant
    let isSelected: Bool
    var activeFilter: RestaurantType = .visited
    var showColors: Bool = false

    // Pin matches the active chip filter, not just .upcoming
    var isPulsing: Bool { showColors && restaurant.primaryType == activeFilter }
    // Color shown when chip colors are active, white otherwise
    var borderColor: Color { showColors ? restaurant.primaryType.color : .white }
    var glowColor: Color { showColors ? restaurant.primaryType.color : Color.white.opacity(0.4) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Radar pulse rings — fire when chip color is active for this pin's type
                if isPulsing {
                    PulseRing(color: borderColor, delay: 0.0)
                    PulseRing(color: borderColor.opacity(0.6), delay: 0.65)
                    PulseRing(color: borderColor.opacity(0.35), delay: 1.3)
                }

                // Glow halo
                Circle()
                    .fill(glowColor.opacity(isSelected ? 0.4 : (showColors ? 0.2 : 0.12)))
                    .frame(width: 58, height: 58)
                    .blur(radius: 10)

                // Photo circle
                AsyncImage(url: URL(string: restaurant.imageURL)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.surfaceLight
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(borderColor, lineWidth: isSelected ? 4 : 3)
                        .shadow(color: glowColor.opacity(0.8), radius: isSelected ? 10 : 6)
                )
            }
            .frame(width: 80, height: 80)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showColors)

            // Label pill
            Text(restaurant.name)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: Color.black.opacity(0.5), radius: 4)
        }
    }
}

// MARK: - Search Result Pin (white circle, pulsing)
struct SearchResultPinView: View {
    let place: MapPlace
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Pulse ring
                Circle()
                    .stroke(Color.white.opacity(pulse ? 0 : 0.6), lineWidth: 2)
                    .frame(width: pulse ? 70 : 48, height: pulse ? 70 : 48)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)

                // White circle with fork icon
                ZStack {
                    Circle().fill(Color.white).frame(width: 44, height: 44)
                        .shadow(color: Color.white.opacity(0.6), radius: 10)
                    Image(systemName: "fork.knife")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.appBg)
                }
            }
            .frame(width: 70, height: 70)
            .onAppear { pulse = true }

            // Name label
            Text(place.name)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.black.opacity(0.75))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: Color.black.opacity(0.5), radius: 4)
        }
    }
}

// MARK: - Nearby POI Pin
struct NearbyPinView: View {
    let place: NearbyPlace
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(place.color.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .blur(radius: 4)
                Circle()
                    .fill(Color.surface.opacity(0.9))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(place.color.opacity(0.5), lineWidth: 1.5))
                Image(systemName: place.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(place.color)
            }
            .scaleEffect(appeared ? 1 : 0.4)
            .opacity(appeared ? 1 : 0)

            Text(place.name)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(Color.white.opacity(0.7))
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(Double.random(in: 0...0.4))) {
                appeared = true
            }
        }
    }
}



// MARK: - Map Stats Chip
struct MapStatsChip: View {
    let count: Int
    let type: RestaurantType
    var chipColorsActive: Bool = false

    var label: String {
        if count == 0 { return "No \(type.label)" }
        if count == 1 { return "1 \(type.label)" }
        return "\(count)+ \(type.label) places"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(chipColorsActive ? type.color : Color.white.opacity(0.6))
                .frame(width: 6, height: 6)
                .shadow(color: chipColorsActive ? type.color : .clear, radius: 4)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .tracking(0.3)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .overlay(Capsule().stroke(
            chipColorsActive ? type.color.opacity(0.3) : Color.white.opacity(0.08),
            lineWidth: 1
        ))
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.3), radius: 8)
        .animation(.spring(response: 0.25), value: chipColorsActive)
    }
}

// MARK: - Filter Chip
struct FilterChip: View {
    let label: String
    let icon: String
    let isActive: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6)
            }
            .foregroundColor(isActive ? color : Color.white.opacity(0.7))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(isActive ? color.opacity(0.18) : Color.black.opacity(0.4))
            .background(.ultraThinMaterial)
            .overlay(Capsule().stroke(isActive ? color.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(Capsule())
            .shadow(color: isActive ? color.opacity(0.3) : Color.black.opacity(0.2), radius: isActive ? 10 : 4)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)
    }
}

// MARK: - RestaurantType chip icon
extension RestaurantType {
    var chipIcon: String {
        switch self {
        case .visited:  return "checkmark.circle.fill"
        case .upcoming: return "calendar.badge.clock"
        case .wishlist: return "bookmark.fill"
        }
    }
}

// MARK: - Route Pane
struct RoutePaneView: View {
    let destinationName: String
    let route: MKRoute?
    let isLoading: Bool
    let onClose: () -> Void
    let onNavigate: () -> Void
    @State private var transportMode = 0
    @State private var fromLocation = "Home · Los Angeles"

    var distanceString: String {
        guard let r = route else { return "--" }
        return String(format: "%.1f mi", r.distance / 1609.34)
    }
    var timeString: String {
        guard let r = route else { return "--" }
        let mins = Int(r.expectedTravelTime / 60)
        return mins >= 60 ? "\(mins/60)h \(mins%60)m" : "\(mins) min"
    }

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.2)).frame(width: 36, height: 4)

            HStack {
                Text("Directions").font(.system(size: 16, weight: .black)).foregroundColor(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 28, height: 28).background(Color.white.opacity(0.1)).clipShape(Circle())
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    Circle().fill(Color.blue).frame(width: 10, height: 10).shadow(color: .blue, radius: 4)
                    Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 24)
                    Circle().fill(Color.accentUpcoming).frame(width: 10, height: 10)
                        .shadow(color: Color.accentUpcoming, radius: 4)
                }
                .padding(.top, 5)
                VStack(spacing: 10) {
                    EditableRouteFieldView(label: "FROM", value: $fromLocation)
                    RouteFieldView(label: "TO", value: destinationName)
                }
            }

            HStack {
                HStack(spacing: 8) {
                    ForEach([(0, "car.fill"), (1, "figure.walk")], id: \.0) { idx, icon in
                        Button(action: { transportMode = idx }) {
                            Image(systemName: icon).font(.system(size: 14))
                                .foregroundColor(transportMode == idx ? Color.appBg : Color.gray)
                                .frame(width: 40, height: 40)
                                .background(transportMode == idx ? Color.white : Color.white.opacity(0.05))
                                .clipShape(Circle())
                                .shadow(color: transportMode == idx ? Color.white.opacity(0.3) : .clear, radius: 8)
                        }
                    }
                }
                Spacer()
                if isLoading {
                    VStack(spacing: 4) {
                        ProgressView().tint(.white).scaleEffect(0.9)
                        Text("Calculating...").font(.system(size: 9)).foregroundColor(.gray)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(distanceString).font(.system(size: 24, weight: .black)).foregroundColor(.white)
                        Text(timeString.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(1)
                    }
                }
            }

            Button(action: onNavigate) {
                HStack(spacing: 8) {
                    Image(systemName: "location.north.fill").font(.system(size: 14, weight: .semibold))
                    Text("Start Navigation").font(.system(size: 14, weight: .black))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(route != nil ? Color.accentVisited : Color.gray.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: route != nil ? Color.accentVisited.opacity(0.4) : .clear, radius: 14)
            }
            .disabled(route == nil || isLoading)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .background(Color.surface.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(Color.white.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.5), radius: 40)
    }
}

struct RouteFieldView: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundColor(.gray).tracking(1.5)
            Text(value).font(.system(size: 12, weight: .bold)).foregroundColor(.white).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.05), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Navigation Step Banner
struct NavigationStepBanner: View {
    @ObservedObject var navManager: NavigationManager

    var turnIcon: String {
        let inst = navManager.currentInstruction.lowercased()
        if inst.contains("left")   { return "arrow.turn.up.left" }
        if inst.contains("right")  { return "arrow.turn.up.right" }
        if inst.contains("u-turn") { return "arrow.uturn.left" }
        if inst.contains("arrive") { return "mappin.circle.fill" }
        return "arrow.up"
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: turnIcon)
                .font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                .frame(width: 54, height: 54)
                .background(Color.accentVisited)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.accentVisited.opacity(0.5), radius: 12)

            VStack(alignment: .leading, spacing: 3) {
                Text(navManager.distanceToNextStep)
                    .font(.system(size: 13, weight: .black)).foregroundColor(.accentVisited)
                Text(navManager.currentInstruction)
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .background(Color.surface.opacity(0.7))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.4), radius: 20)
    }
}

// MARK: - Navigation Bottom Bar
struct NavigationBottomBar: View {
    @ObservedObject var navManager: NavigationManager
    var onStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("REMAINING").font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(1.5)
                    Text(navManager.remainingDistance).font(.system(size: 22, weight: .black)).foregroundColor(.white)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("ETA").font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(1.5)
                    Text(navManager.remainingTime).font(.system(size: 22, weight: .black)).foregroundColor(.white)
                }
            }

            if navManager.steps.count > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<min(navManager.steps.count, 8), id: \.self) { i in
                        Capsule()
                            .fill(i <= navManager.currentStepIndex ? Color.accentVisited : Color.white.opacity(0.15))
                            .frame(width: i == navManager.currentStepIndex ? 20 : 6, height: 4)
                            .animation(.spring(response: 0.3), value: navManager.currentStepIndex)
                    }
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Button(action: { navManager.prevStep() }) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        .frame(width: 44, height: 44).background(Color.white.opacity(0.08))
                        .clipShape(Circle()).overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
                .opacity(navManager.currentStepIndex == 0 ? 0.3 : 1)

                Button(action: { navManager.nextStep() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill").font(.system(size: 16))
                        Text(navManager.currentStepIndex == navManager.steps.count - 1 ? "Arrive" : "Next Step")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(Color.appBg)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.accentVisited)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.accentVisited.opacity(0.35), radius: 10)
                }

                Button(action: { onStop() }) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        .frame(width: 44, height: 44).background(Color.accentUpcoming.opacity(0.2))
                        .clipShape(Circle()).overlay(Circle().stroke(Color.accentUpcoming.opacity(0.4), lineWidth: 1))
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .background(Color.surface.opacity(0.7))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color.black.opacity(0.5), radius: 30)
    }
}

// MARK: - City Search Sheet
struct CitySearchView: View {
    var onSearch: (String) -> Void
    @State private var cityText = ""
    @Environment(\.dismiss) var dismiss

    let suggestions = ["Paris, France", "Tokyo, Japan", "New York, NY", "London, UK", "Barcelona, Spain", "Rome, Italy", "Sydney, Australia", "Dubai, UAE"]

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Find in City")
                        .font(.system(size: 18, weight: .black)).foregroundColor(.white)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .frame(width: 32, height: 32).background(Color.white.opacity(0.1)).clipShape(Circle())
                    }
                }
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)

                HStack(spacing: 12) {
                    Image(systemName: "building.2.fill").font(.system(size: 14)).foregroundColor(.gray)
                    TextField("Enter city name...", text: $cityText)
                        .font(.system(size: 14, weight: .medium)).foregroundColor(.white).tint(.white)
                        .autocapitalization(.words)
                        .onSubmit { if !cityText.isEmpty { onSearch("restaurants in \(cityText)") } }
                    if !cityText.isEmpty {
                        Button(action: { cityText = "" }) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.gray)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color.surface)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 24).padding(.bottom, 20)

                Button(action: { if !cityText.isEmpty { onSearch("restaurants in \(cityText)") } }) {
                    Text("Search Restaurants")
                        .font(.system(size: 14, weight: .black)).foregroundColor(Color.appBg)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(cityText.isEmpty ? Color.white.opacity(0.3) : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(cityText.isEmpty)
                .padding(.horizontal, 24).padding(.bottom, 24)

                Divider().background(Color.white.opacity(0.05))

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("POPULAR CITIES").font(.system(size: 9, weight: .bold)).foregroundColor(.gray).tracking(1.5)
                            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
                        ForEach(suggestions, id: \.self) { city in
                            Button(action: { onSearch("restaurants in \(city)") }) {
                                HStack(spacing: 14) {
                                    Image(systemName: "globe").font(.system(size: 16)).foregroundColor(.accentSaved)
                                        .frame(width: 36, height: 36).background(Color.accentSaved.opacity(0.1)).clipShape(Circle())
                                    Text(city).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                                    Spacer()
                                    Image(systemName: "arrow.right").font(.system(size: 12)).foregroundColor(.gray.opacity(0.4))
                                }
                                .padding(.horizontal, 24).padding(.vertical, 12)
                            }
                            Divider().background(Color.white.opacity(0.04)).padding(.horizontal, 24)
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Editable Route Field
struct EditableRouteFieldView: View {
    let label: String
    @Binding var value: String
    @State private var isEditing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundColor(.gray).tracking(1.5)
            if isEditing {
                TextField("Enter starting location", text: $value)
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.white).tint(.white)
                    .focused($focused)
                    .onSubmit { isEditing = false }
                    .onAppear { focused = true }
            } else {
                HStack {
                    Text(value).font(.system(size: 12, weight: .bold)).foregroundColor(.white).lineLimit(1)
                    Spacer()
                    Button(action: { isEditing = true }) {
                        Image(systemName: "pencil").font(.system(size: 10)).foregroundColor(.gray)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(isEditing ? Color.white.opacity(0.2) : Color.white.opacity(0.05), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.spring(response: 0.2), value: isEditing)
    }
}
