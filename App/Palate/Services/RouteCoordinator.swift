import SwiftUI
import MapKit
import Combine

class RouteCoordinator: ObservableObject {
    @Published var pendingRestaurant: Restaurant? = nil

    func requestRoute(to restaurant: Restaurant) {
        pendingRestaurant = restaurant
    }

    func consume() -> Restaurant? {
        let r = pendingRestaurant
        pendingRestaurant = nil
        return r
    }
}
