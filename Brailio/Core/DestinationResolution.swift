import MapKit

enum DestinationResolution {
    static func normalize(_ text: String) -> String { text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US")).split(whereSeparator:{ !$0.isLetter && !$0.isNumber }).joined(separator:" ") }
    static let nearbyRadius: Double = 5000
    static func distance(_ item: MKMapItem, from location: CLLocation) -> Double {
        let coordinate = item.placemark.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite, CLLocationCoordinate2DIsValid(coordinate) else { return .infinity }
        return location.distance(from: CLLocation(latitude:coordinate.latitude,longitude:coordinate.longitude))
    }
    static func nearby(_ places: [MKMapItem], location: CLLocation, radius: Double = nearbyRadius) -> [MKMapItem] {
        guard radius.isFinite, radius > 0 else { return [] }
        return places.enumerated().filter { distance($0.element,from:location) <= radius }.sorted {
            let a=distance($0.element,from:location),b=distance($1.element,from:location)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
    static func searchText(_ query: String) -> String {
        let trimmed=query.trimmingCharacters(in:.whitespacesAndNewlines)
        for prefix in ["nearest ","closest ","nearby "] where trimmed.lowercased().hasPrefix(prefix) { return String(trimmed.dropFirst(prefix.count)) }
        return trimmed
    }
    static func distanceLabel(_ item: MKMapItem, from location: CLLocation?) -> String {
        guard let location else { return "Distance unavailable" }
        let metres=distance(item,from:location)
        guard metres.isFinite else { return "Distance unavailable" }
        return metres < 1000 ? "\(Int((metres / 10).rounded()) * 10) metres away" : String(format:"%.1f kilometres away",metres/1000)
    }
    static func select(_ query: String, places: [MKMapItem], location: CLLocation) -> MKMapItem? {
        // A single far-away result must not bypass nearby search or become an automatic route.
        let places=nearby(places,location:location)
        if places.count == 1 { return places[0] }
        let query=normalize(query)
        if query.hasPrefix("nearest ") || query.hasPrefix("closest ") {
            return places.min { location.distance(from:CLLocation(latitude:$0.placemark.coordinate.latitude,longitude:$0.placemark.coordinate.longitude)) < location.distance(from:CLLocation(latitude:$1.placemark.coordinate.latitude,longitude:$1.placemark.coordinate.longitude)) }
        }
        let exact=places.filter { normalize($0.name ?? "") == query || normalize($0.placemark.title ?? "") == query }
        return exact.count == 1 ? exact[0] : nil
    }
}
