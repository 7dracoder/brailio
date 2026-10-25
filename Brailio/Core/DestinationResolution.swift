import MapKit

enum DestinationResolution {
    static func normalize(_ text: String) -> String { text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US")).split(whereSeparator:{ !$0.isLetter && !$0.isNumber }).joined(separator:" ") }
    static func select(_ query: String, places: [MKMapItem], location: CLLocation) -> MKMapItem? {
        if places.count == 1 { return places[0] }
        let query=normalize(query)
        if query.hasPrefix("nearest ") || query.hasPrefix("closest ") {
            return places.min { location.distance(from:CLLocation(latitude:$0.placemark.coordinate.latitude,longitude:$0.placemark.coordinate.longitude)) < location.distance(from:CLLocation(latitude:$1.placemark.coordinate.latitude,longitude:$1.placemark.coordinate.longitude)) }
        }
        let exact=places.filter { normalize($0.name ?? "") == query || normalize($0.placemark.title ?? "") == query }
        return exact.count == 1 ? exact[0] : nil
    }
}
