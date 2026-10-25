import MapKit
import CoreLocation
import SwiftUI

enum TactileCue: String, CaseIterable {
    case left = "Left", right = "Right", straight = "Continue", nearby = "Checkpoint nearby"
    var dots: Set<Int> {
        switch self { case .left: return [1]; case .right: return [1,2]; case .straight: return [1,2,3]; case .nearby: return [1,2,3,4] }
    }
    static func instruction(_ text: String) -> TactileCue {
        let text = text.lowercased()
        if text.contains("left") { return .left }
        if text.contains("right") { return .right }
        return .straight
    }
}

@MainActor
final class RouteGuide: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var location: CLLocation?
    @Published var places: [MKMapItem] = []
    @Published var route: WalkingRoute?
    @Published var index = 0
    @Published var guiding = false
    @Published var suspended = false
    @Published var busy = false
    @Published var status = "Enable location, then search for a destination."
    @Published var error: String?
    @Published var feedback = RouteFeedback.paused
    @Published var proximityEnabled = true
    @Published var provider = RouteProvider.apple
    var onCue: ((TactileCue) -> Void)?
    var onFeedback: ((RouteFeedback) -> Void)?
    private let manager = CLLocationManager()
    private var search: MKLocalSearch?
    private var directions: MKDirections?
    private var watchdog: Task<Void, Never>?
    private var routeRequest = UUID()
    private var path: RoutePath?
    private var progress = 0.0
    private var filter = RouteDeviationFilter()
    private var lastAssessed = Date.distantPast
    private var locationRequested = false
    private var selectedPlace: MKMapItem?
    var steps: [WalkingStep] { route?.steps ?? [] }
    var current: WalkingStep? { steps.indices.contains(index) ? steps[index] : nil }
    var googleURL: URL? { route.map { GoogleRouting.directionsURL(destination: $0.destination) } }
    override init() {
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 1; manager.activityType = .fitness
        #if DEBUG
        if ProcessInfo.processInfo.environment["BRAILIO_UI_TEST_ROUTE"] == "1" {
            let points = [CLLocationCoordinate2D(latitude:37,longitude:-122),CLLocationCoordinate2D(latitude:37.005,longitude:-122)]
            loadTestRoute(WalkingRoute(provider:.apple,points:points,steps:[WalkingStep(instructions:"Continue north",points:points)],destination:points[1]))
        }
        #endif
    }
    func enable() {
        locationRequested = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation()
        default: error = "Location is disabled. Allow location while using Brailio in iPhone Settings."; if guiding { publish(.uncertain, message: "Location unavailable. Guidance uncertain.") }
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if !locationRequested { manager.stopUpdatingLocation(); return }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.startUpdatingLocation() }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { status = "Location permission denied."; if guiding { publish(.uncertain, message: status) } }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, latest.timestamp >= (location?.timestamp ?? .distantPast) else { return }
        ingest(latest)
    }
    func ingest(_ latest: CLLocation, now: Date = Date()) {
        location = latest
        guard guiding, !suspended, let path else { return }
        guard latest.timestamp > lastAssessed else { return }; lastAssessed = latest.timestamp
        let assessment = RouteAlignment.evaluate(latest, path: path, progress: progress, now: now)
        progress = assessment.progress
        let feedback = filter.update(ProximityFeedback.route(assessment,length:path.total,enabled:proximityEnabled))
        switch feedback.kind {
        case .aligned: publish(feedback, message: "Aligned with the route. Silent feedback. No crossing or obstacle detection.")
        case .approaching: publish(feedback, message: "Approach pulses grow stronger and faster as the remaining route shortens. No crossing or obstacle detection.")
        case .deviated: publish(feedback, message: "Route deviation. Stronger pulses mean greater error. Stop and check your surroundings before correcting.")
        case .uncertain: publish(feedback, message: "Position or travel direction uncertain. Two short pulses. Wait for reliable GPS and movement.")
        case .end: publish(feedback, message: "Final route point nearby. Approach pulses continue until Stop. Confirm the destination yourself.")
        case .paused: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { self.error = error.localizedDescription; if guiding { publish(.uncertain, message: "GPS unavailable. Two short pulses indicate uncertainty.") } }
    func find(_ query: String) async {
        guard let location, Date().timeIntervalSince(location.timestamp) < 20, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else { enable(); error = "Wait for a location fix, then search again."; return }
        busy = true; error = nil; defer { busy = false }; search?.cancel()
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 10_000, longitudinalMeters: 10_000)
        let search = MKLocalSearch(request: request); self.search = search
        do { places = try await search.start().mapItems; if places.isEmpty { status = "No places found. Try a more specific address." } }
        catch { self.error = error.localizedDescription }
    }
    private func waitForLocation() async throws -> CLLocation {
        enable(); status="Getting your location"
        for _ in 0..<150 {
            try Task.checkCancellation()
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { throw ServiceError.message("Allow location in iPhone Settings to start a route.") }
            if let location, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50, (-1...6).contains(Date().timeIntervalSince(location.timestamp)) { return location }
            try await Task.sleep(for:.milliseconds(200))
        }
        throw ServiceError.message("Could not get a precise location. Move to an open area and retry.")
    }
    func prepareDestination(_ query: String) async {
        stop(); provider = .apple; route=nil; places=[]; error=nil; busy=true
        defer { busy=false }
        #if DEBUG
        if ProcessInfo.processInfo.environment["BRAILIO_UI_TEST_ROUTE"] == "1" {
            let points=[CLLocationCoordinate2D(latitude:37,longitude:-122),CLLocationCoordinate2D(latitude:37.005,longitude:-122)]
            loadTestRoute(WalkingRoute(provider:.apple,points:points,steps:[WalkingStep(instructions:"Continue north",points:points)],destination:points[1])); return
        }
        #endif
        do {
            _ = try await waitForLocation()
            await find(query); try Task.checkCancellation()
            guard error == nil, let location else { return }
            guard let place=DestinationResolution.select(query,places:places,location:location) else { status=places.isEmpty ? "No places found" : "Choose the intended destination"; return }
            await preview(place)
        } catch is CancellationError { return } catch { self.error=error.localizedDescription; status=error.localizedDescription }
    }
    func selectStep(_ value: Int) { guard steps.indices.contains(value) else { return }; index=value }
    func chooseProvider(_ provider: RouteProvider) {
        stop(); self.provider = provider; route = nil; path = nil
        UserDefaults.standard.set(provider.rawValue, forKey: "routeProvider")
        status = provider == .google ? "Google Maps selected. In-app routes require server setup." : "Apple Maps selected. Search and preview a walking route."
    }
    func preview(_ place: MKMapItem) async {
        stop(); selectedPlace = place; let requestID = UUID(); routeRequest = requestID
        let location: CLLocation
        do { location=try await waitForLocation() } catch { self.error=error.localizedDescription; return }
        guard requestID == routeRequest, !Task.isCancelled else { return }
        busy = true; error = nil; route = nil; path = nil; index = 0; progress = 0; filter = RouteDeviationFilter(); lastAssessed = .distantPast
        defer { if routeRequest == requestID { busy = false } }
        do {
            let walking: WalkingRoute
            if provider == .google { walking = try await GoogleRouting.route(from: location.coordinate, to: place.placemark.coordinate) }
            else {
                let request = MKDirections.Request(); request.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate)); request.destination = place; request.transportType = .walking
                let directions = MKDirections(request: request); self.directions = directions
                guard let route = try await directions.calculate().routes.first else { throw ServiceError.message("No walking route is available.") }
                func points(_ line: MKPolyline) -> [CLLocationCoordinate2D] { (0..<line.pointCount).map { line.points()[$0].coordinate } }
                walking = WalkingRoute(provider: .apple, points: points(route.polyline), steps: route.steps.filter { !$0.instructions.isEmpty }.map { WalkingStep(instructions: $0.instructions, points: points($0.polyline)) }, destination: place.placemark.coordinate)
            }
            guard requestID == routeRequest, !Task.isCancelled else { return }
            let path = RoutePath(walking.points); guard path.total > 1 else { throw ServiceError.message("No usable walking route geometry.") }
            route = walking; self.path = path
            status = walking.provider.title + ". Review before starting. Walking routes may be missing sidewalks or pedestrian paths. Silence never establishes a safe crossing."
        } catch { guard requestID == routeRequest else { return }; self.error = error.localizedDescription; status = error.localizedDescription }
    }
    func start(updatingLocation: Bool = true) {
        guard path != nil else { return }; guiding = true; suspended = false; filter = RouteDeviationFilter(); lastAssessed = .distantPast
        #if DEBUG
        let fixture = ProcessInfo.processInfo.environment["BRAILIO_UI_TEST_ROUTE"] == "1"
        #else
        let fixture = false
        #endif
        if updatingLocation && !fixture { enable() }
        publish(.uncertain, message: "Checking GPS and direction of travel. Two short pulses mean uncertain.")
        if let location { ingest(location) }
        watchdog?.cancel(); watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.guiding else { return }
                if !self.suspended, self.location.map({ Date().timeIntervalSince($0.timestamp) > 6 }) ?? true { self.filter = RouteDeviationFilter(); self.publish(.uncertain, message: "GPS is stale. Route alignment is unknown.") }
            }
        }
    }
    func suspendFeedback() { guard guiding else { return }; suspended = true; status = "Guidance paused for exploration. Resume to continue."; onFeedback?(.paused) }
    func pauseForHapticFailure(_ message: String) { stop(); status = message; error = message }
    func next() { guard index < steps.count - 1 else { status = "End of route instructions. Confirm the destination yourself."; return }; index += 1; if let current { onCue?(.instruction(current.instructions)) } }
    func reroute() async { guard let selectedPlace else { return }; await preview(selectedPlace) }
    func stop() { locationRequested = false; guiding = false; suspended = false; watchdog?.cancel(); watchdog = nil; manager.stopUpdatingLocation(); status = "Guidance stopped."; routeRequest = UUID(); busy = false; search?.cancel(); directions?.cancel(); publish(.paused, message: status) }
    private func publish(_ feedback: RouteFeedback, message: String) { self.feedback = feedback; status = message; if !suspended { onFeedback?(feedback) } }
    #if DEBUG
    func loadTestRoute(_ route: WalkingRoute) { self.route = route; path = RoutePath(route.points); progress = 0; filter = RouteDeviationFilter(); lastAssessed = .distantPast }
    #endif
}
