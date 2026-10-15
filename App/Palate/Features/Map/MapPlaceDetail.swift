import SwiftUI
import MapKit

// MARK: - Real place from MKLocalSearch
struct MapPlace: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem

    var name: String { mapItem.name ?? "Unknown" }
    var address: String {
        let p = mapItem.placemark
        let parts = [p.subThoroughfare, p.thoroughfare, p.locality, p.administrativeArea]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }
    var phone: String { mapItem.phoneNumber ?? "" }
    var url: URL? { mapItem.url }
    var coordinate: CLLocationCoordinate2D { mapItem.placemark.coordinate }
    var category: String {
        guard let cats = mapItem.pointOfInterestCategory else { return "restaurant" }
        switch cats {
        case .cafe:        return "cafe"
        case .brewery, .winery, .nightlife: return "bar"
        default:           return "restaurant"
        }
    }
}

// MARK: - Map Place Detail Pane
struct MapPlaceDetailPane: View {
    let place: MapPlace
    @Binding var isPresented: Bool
    var showToast: (String) -> Void
    var onGetDirections: (MapPlace) -> Void
    var onLog: (MapPlace) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { withAnimation { isPresented = false } }

                VStack(spacing: 0) {
                    // Handle
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 36, height: 4)
                        .padding(.top, 12)
                        .padding(.bottom, 16)

                    // Name + category badge
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(place.name)
                                .font(.system(size: 22, weight: .black))
                                .foregroundColor(.white)
                                .tracking(-0.5)
                            Text(place.address)
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                                .lineLimit(2)
                        }
                        Spacer()
                        categoryBadge
                    }
                    .padding(.horizontal, geo.safeAreaInsets.leading + 24)
                    .padding(.bottom, 20)

                    // Phone if available
                    if !place.phone.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 11)).foregroundColor(.gray)
                            Text(place.phone)
                                .font(.system(size: 12, weight: .medium)).foregroundColor(Color.gray.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, geo.safeAreaInsets.leading + 24)
                        .padding(.bottom, 16)
                    }

                    // Action buttons
                    HStack(spacing: 10) {
                        // Directions
                        Button(action: { onGetDirections(place) }) {
                            VStack(spacing: 5) {
                                Image(systemName: "location.north.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.accentSaved)
                                Text("DIRECTIONS")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white).tracking(0.8)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.accentSaved.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.accentSaved.opacity(0.3), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        // Share
                        Button(action: { showToast("Link Copied") }) {
                            VStack(spacing: 5) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 15)).foregroundColor(.white)
                                Text("SHARE")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white).tracking(0.8)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        // Log
                        Button(action: { onLog(place) }) {
                            VStack(spacing: 5) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 15)).foregroundColor(.accentVisited)
                                Text("LOG")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white).tracking(0.8)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.accentVisited.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.accentVisited.opacity(0.3), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(.horizontal, geo.safeAreaInsets.leading + 24)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 20)
                }
                .padding(.bottom, 90) // clear tab bar
                .background(
                    Color.surface
                        .overlay(Color.white.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 40)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    var categoryBadge: some View {
        let (label, icon, color) = categoryInfo
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(.system(size: 9, weight: .bold)).tracking(0.5)
        }
        .foregroundColor(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.1))
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
        .clipShape(Capsule())
    }

    var categoryInfo: (String, String, Color) {
        switch place.category {
        case "cafe": return ("CAFÉ", "cup.and.saucer.fill", Color(hex: "#F59E0B"))
        case "bar":  return ("BAR", "wineglass.fill", Color(hex: "#A78BFA"))
        default:     return ("RESTAURANT", "fork.knife", Color.accentVisited)
        }
    }
}
