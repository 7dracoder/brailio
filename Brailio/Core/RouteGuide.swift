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
    private var searchRequest=UUID()
    private var search: MKLocalSearch?
    private var directions: MKDirections?
    private var watchdog: Task<Void, Never>?
    private var routeRequest = UUID()
    private var path: RoutePath?
    private var progress = 0.0
    private var filter = RouteDeviationFilter()
    private var lastAssessed = Date.distantPast
    private var locationRequested = false
    private var heading: RouteHeading?
    private var lastHeadingAssessed = Date.distantPast
    private var lastRecovery = Date.distantPast
    private(set) var locationUpdateCount = 0
    var locationAccuracy: Double? { location?.horizontalAccuracy }
    var locationAge: TimeInterval? { location.map { Date().timeIntervalSince($0.timestamp) } }
    private var selectedPlace: MKMapItem?
    var steps: [WalkingStep] { route?.steps ?? [] }
    var current: WalkingStep? { steps.indices.contains(index) ? steps[index] : nil }
    var googleURL: URL? { route.map { GoogleRouting.directionsURL(destination: $0.destination) } }
    override init() {
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone; manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = kCLHeadingFilterNone; manager.headingOrientation = .portrait
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
        case .authorizedAlways, .authorizedWhenInUse: startSensors()
        default: error = "Location is disabled. Allow location while using Brailio in iPhone Settings."; if guiding { publish(.uncertain, message: "Location unavailable. Guidance uncertain.") }
        }
    }
    private func startSensors() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if !locationRequested { manager.stopUpdatingLocation(); return }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { startSensors() }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { status = "Location permission denied."; if guiding { publish(.uncertain, message: status) } }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locationRequested, let latest = locations.last, latest.timestamp >= (location?.timestamp ?? .distantPast) else { return }
        ingest(latest)
    }
    func ingest(_ latest: CLLocation, now: Date = Date()) {
        guard latest.timestamp >= (location?.timestamp ?? .distantPast) else { return }
        if latest.timestamp > (location?.timestamp ?? .distantPast) { locationUpdateCount += 1 }
        location = latest
        guard guiding, !suspended, let path else { return }
        guard latest.timestamp > lastAssessed else { return }; lastAssessed = latest.timestamp
        assess(latest, path: path, now: now)
    }
    func ingestHeading(_ value: RouteHeading, now: Date = Date()) {
        guard value.timestamp > (heading?.timestamp ?? .distantPast) else { return }
        heading = value
        guard guiding, !suspended, value.reliable(at: now), value.timestamp > lastHeadingAssessed,
              let location, !RouteAlignment.hasReliableCourse(location), let path,
              let projection = path.projection(location.coordinate, progress: progress), projection.distance <= 8 else { return }
        lastHeadingAssessed = value.timestamp
        // New compass observations can confirm phone direction. They cannot confirm a cached lateral GPS deviation.
        assess(location, path: path, now: now)
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard locationRequested else { return }
        ingestHeading(RouteHeading(degrees:newHeading.trueHeading,accuracy:newHeading.headingAccuracy,timestamp:newHeading.timestamp))
    }
    private func assess(_ latest: CLLocation, path: RoutePath, now: Date) {
        let assessment = RouteAlignment.evaluate(latest, path: path, progress: progress, now: now, heading: heading)
        let phoneDirection = assessment.angle != nil && !RouteAlignment.hasReliableCourse(latest) && (assessment.distance ?? .infinity) <= 8
        progress = assessment.progress
        let feedback = filter.update(ProximityFeedback.route(assessment,length:path.total,enabled:proximityEnabled))
        switch feedback.kind {
        case .aligned: publish(feedback, message: phoneDirection ? "Phone points along the route. Silent alignment feedback." : "Walking along the route. Silent alignment feedback.")
        case .approaching: publish(feedback, message: phoneDirection ? "Phone points along the route. Approach taps intensify near the destination." : "Walking along the route. Approach taps intensify near the destination.")
        case .deviated: publish(feedback, message: phoneDirection ? "Phone points away from the route. Turn slowly; correction taps ease as it lines up." : "Route deviation. Stronger taps mean greater error. Check your surroundings.")
        case .uncertain:
            let age = now.timeIntervalSince(latest.timestamp)
            let message = age > 6 ? "Refreshing your location. Guidance will resume automatically." : latest.horizontalAccuracy > 18 ? "Location accuracy is low. Move to an open area; guidance resumes automatically." : "Location updated. Point the phone ahead or walk to establish direction."
            publish(feedback, message: message)
        case .end: publish(feedback, message: "Final route point nearby. Approach pulses continue until Stop. Confirm the destination yourself.")
        case .paused: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { self.error = error.localizedDescription; if guiding { publish(.uncertain, message: "GPS unavailable. Two short pulses indicate uncertainty.") } }
    func find(_ query: String, radius: Double = DestinationResolution.nearbyRadius) async {
        guard let location, (-1...20).contains(Date().timeIntervalSince(location.timestamp)), location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else { enable(); error = "Wait for a location fix, then search again."; return }
        guard radius.isFinite, (1...20_000).contains(radius) else { error="Invalid search area."; return }
        let id=UUID(); searchRequest=id
        busy = true; error = nil; places=[]; search?.cancel()
        status=radius <= DestinationResolution.nearbyRadius ? "Searching nearby places within five kilometres." : "Searching within twenty kilometres. Choose a result to start."
        defer { if searchRequest == id { busy = false } }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = DestinationResolution.searchText(query)
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        if #available(iOS 18.0, *) { request.regionPriority = .required }
        let search = MKLocalSearch(request: request); self.search = search
        do {
            let results=try await search.start().mapItems
            try Task.checkCancellation(); guard searchRequest == id else { return }
            places=DestinationResolution.nearby(results,location:location,radius:radius)
            status=places.isEmpty ? "No nearby places found. Try a more specific name or Search wider." : "\(places.count) places, nearest first."
        } catch is CancellationError { return }
        catch {
            guard searchRequest == id else { return }
            if let mapError=error as? MKError, mapError.code == .placemarkNotFound { places=[]; status="No nearby places found. Try another name or Search wider." }
            else { self.error=error.localizedDescription }
        }
    }
    func findWider(_ query: String) async {
        do { _ = try await waitForLocation(); try Task.checkCancellation(); await find(query,radius:20_000) }
        catch is CancellationError { return }
        catch { self.error=error.localizedDescription }
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
            guard let place=DestinationResolution.select(query,places:places,location:location) else { status=places.isEmpty ? "No nearby places found. Try another name or Search wider." : "Nearby places, nearest first. Choose the intended destination."; return }
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
        guard path != nil else { return }; let continuing = guiding; guiding = true; suspended = false; if !continuing { filter = RouteDeviationFilter(); lastAssessed = .distantPast; lastRecovery = .distantPast }
        #if DEBUG
        let fixture = ProcessInfo.processInfo.environment["BRAILIO_UI_TEST_ROUTE"] == "1"
        #else
        let fixture = false
        #endif
        if updatingLocation && !fixture { enable() }
        publish(.uncertain, message: "Guidance started. Getting your location and direction.")
        if let location { ingest(location) }
        watchdog?.cancel(); watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.guiding else { return }
                self.checkLocationFreshness()
            }
        }
    }
    func checkLocationFreshness(now: Date = Date(), recover: Bool = true) {
        guard guiding, !suspended else { return }
        guard location.map({ now.timeIntervalSince($0.timestamp) > 6 }) ?? true else { return }
        filter = RouteDeviationFilter()
        publish(.uncertain, message: "Refreshing your location. Guidance will resume automatically.")
        if recover, locationRequested, now.timeIntervalSince(lastRecovery) >= 8,
           manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            lastRecovery = now
            manager.stopUpdatingLocation(); startSensors()
        }
    }
    func suspendFeedback() { guard guiding else { return }; suspended = true; status = "Guidance paused for exploration. Resume to continue."; onFeedback?(.paused) }
    func pauseForHapticFailure(_ message: String) { stop(); status = message; error = message }
    func next() { guard index < steps.count - 1 else { status = "End of route instructions. Confirm the destination yourself."; return }; index += 1; if let current { onCue?(.instruction(current.instructions)) } }
    func reroute() async { guard let selectedPlace else { return }; await preview(selectedPlace) }
    func stop() { locationRequested = false; guiding = false; suspended = false; watchdog?.cancel(); watchdog = nil; manager.stopUpdatingLocation(); manager.stopUpdatingHeading(); heading=nil; lastHeadingAssessed = .distantPast; status = "Guidance stopped."; routeRequest = UUID(); searchRequest=UUID(); busy = false; search?.cancel(); directions?.cancel(); publish(.paused, message: status) }
    private func publish(_ feedback: RouteFeedback, message: String) { self.feedback = feedback; status = message; if !suspended { onFeedback?(feedback) } }
    #if DEBUG
    func loadTestRoute(_ route: WalkingRoute) { self.route = route; path = RoutePath(route.points); progress = 0; filter = RouteDeviationFilter(); lastAssessed = .distantPast }
    #endif
}
