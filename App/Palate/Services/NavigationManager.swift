import MapKit
import CoreLocation
import Combine

class NavigationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isNavigating = false
    @Published var currentStepIndex = 0
    @Published var currentInstruction = ""
    @Published var distanceToNextStep = ""
    @Published var remainingDistance = ""
    @Published var remainingTime = ""
    @Published var steps: [MKRoute.Step] = []

    private let locationManager = CLLocationManager()
    private var route: MKRoute?

    override init() {
        super.init()
        locationManager.delegate = self
        // Use navigation accuracy ONLY during active navigation
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func startNavigation(route: MKRoute, destination: Restaurant) {
        self.route = route
        self.steps = route.steps.filter { !$0.instructions.isEmpty }
        self.currentStepIndex = 0
        self.isNavigating = true
        updateStep()
        updateRemaining(route: route)
        // Switch to best accuracy only when navigating
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5
        locationManager.startUpdatingLocation()
    }

    func stopNavigation() {
        isNavigating = false
        currentStepIndex = 0
        steps = []
        route = nil
        locationManager.stopUpdatingLocation()
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func nextStep() {
        guard currentStepIndex < steps.count - 1 else { stopNavigation(); return }
        currentStepIndex += 1
        updateStep()
    }

    func prevStep() {
        guard currentStepIndex > 0 else { return }
        currentStepIndex -= 1
        updateStep()
    }

    private func updateStep() {
        guard currentStepIndex < steps.count else { return }
        let step = steps[currentStepIndex]
        currentInstruction = step.instructions
        distanceToNextStep = step.distance < 200
            ? "\(Int(step.distance)) m"
            : String(format: "%.1f mi", step.distance / 1609.34)
    }

    private func updateRemaining(route: MKRoute) {
        remainingDistance = String(format: "%.1f mi", route.distance / 1609.34)
        let mins = Int(route.expectedTravelTime / 60)
        remainingTime = mins >= 60 ? "\(mins/60)h \(mins%60)m" : "\(mins) min"
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isNavigating, currentStepIndex < steps.count - 1,
              let coord = locations.last?.coordinate else { return }
        let stepEnd = steps[currentStepIndex].polyline.coordinate
        let dist = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            .distance(from: CLLocation(latitude: stepEnd.latitude, longitude: stepEnd.longitude))
        if dist < 30 { DispatchQueue.main.async { self.nextStep() } }
    }
}
