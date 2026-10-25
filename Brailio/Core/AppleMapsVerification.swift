#if DEBUG
import MapKit

@MainActor enum AppleMapsVerification {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["BRAILIO_VERIFY_MAPKIT"] == "1" else { return }
        Task {
            var result:[String:Any]=[:]
            do {
                let origin=CLLocationCoordinate2D(latitude:37.3349,longitude:-122.0090)
                let request=MKLocalSearch.Request();request.naturalLanguageQuery="Apple Park Visitor Center"
                request.region=MKCoordinateRegion(center:origin,latitudinalMeters:5000,longitudinalMeters:5000)
                let places=try await MKLocalSearch(request:request).start().mapItems
                guard let destination=places.first else { throw ServiceError.message("No Apple Maps search results") }
                result["searchPassed"]=true
                let routeRequest=MKDirections.Request();routeRequest.source=MKMapItem(placemark:MKPlacemark(coordinate:origin));routeRequest.destination=destination;routeRequest.transportType = .walking
                let routes=try await MKDirections(request:routeRequest).calculate().routes
                result["walkingRoutePassed"]=routes.first.map { $0.polyline.pointCount >= 2 && $0.distance > 0 } ?? false
                result["steps"]=routes.first?.steps.count ?? 0
            } catch { result["error"]=error.localizedDescription }
            let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if let data=try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys) { try? data.write(to:directory.appendingPathComponent("mapkit-verification.json"),options:[.atomic,.completeFileProtection]) }
        }
    }
}
#endif
