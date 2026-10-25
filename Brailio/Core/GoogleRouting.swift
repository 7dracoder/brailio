import Foundation
import MapKit

enum RouteProvider: String, CaseIterable { case apple, google
    var title: String { self == .apple ? "Apple Maps" : "Google Maps" }
}
struct WalkingStep { let instructions: String; let points: [CLLocationCoordinate2D] }
struct WalkingRoute {
    let provider: RouteProvider
    let points: [CLLocationCoordinate2D]
    let steps: [WalkingStep]
    let destination: CLLocationCoordinate2D
}
enum GoogleRouting {
    static func directionsURL(query: String) -> URL {
        var parts = URLComponents(string: "https://www.google.com/maps/dir/")!
        parts.queryItems = [.init(name: "api", value: "1"), .init(name: "destination", value: query), .init(name: "travelmode", value: "walking")]
        return parts.url!
    }
    static func directionsURL(destination: CLLocationCoordinate2D) -> URL {
        var parts = URLComponents(string: "https://www.google.com/maps/dir/")!
        parts.queryItems = [.init(name: "api", value: "1"), .init(name: "destination", value: "\(destination.latitude),\(destination.longitude)"), .init(name: "travelmode", value: "walking")]
        return parts.url!
    }
    static func decode(_ encoded: String, minimumPoints: Int = 2) throws -> [CLLocationCoordinate2D] {
        let bytes = Array(encoded.utf8); var cursor = 0, latitude = 0, longitude = 0
        var points: [CLLocationCoordinate2D] = []
        func delta() throws -> Int {
            var result = 0, shift = 0
            while cursor < bytes.count, shift <= 30 {
                let byte = Int(bytes[cursor]) - 63; cursor += 1
                guard (0...63).contains(byte) else { throw ServiceError.message("Invalid route geometry.") }
                result |= (byte & 0x1f) << shift
                if byte < 0x20 { return result & 1 == 1 ? ~(result >> 1) : result >> 1 }
                shift += 5
            }
            throw ServiceError.message("Incomplete route geometry.")
        }
        guard bytes.count <= 200_000 else { throw ServiceError.message("Route geometry is too large.") }
        while cursor < bytes.count {
            latitude += try delta(); longitude += try delta()
            let point = CLLocationCoordinate2D(latitude: Double(latitude) / 100_000, longitude: Double(longitude) / 100_000)
            guard CLLocationCoordinate2DIsValid(point) else { throw ServiceError.message("Invalid route coordinates.") }
            points.append(point)
        }
        guard points.count >= minimumPoints else { throw ServiceError.message("No walking route geometry.") }
        return points
    }
    static func route(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> WalkingRoute {
        guard let raw = UserDefaults.standard.string(forKey: "backendURL"), let base = URL(string: raw), base.scheme == "https", !BackendAccess.token.isEmpty else { throw ServiceError.message("Google routing needs server setup. Apple Maps remains available.") }
        var request = URLRequest(url: base.appendingPathComponent("route")); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer " + BackendAccess.token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["origin": ["latitude": origin.latitude, "longitude": origin.longitude], "destination": ["latitude": destination.latitude, "longitude": destination.longitude]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw ServiceError.message(message ?? "Google routing is unavailable. Choose Apple Maps or retry.")
        }
        struct Response: Decodable { struct Step: Decodable { let instructions: String; let polyline: String }; let polyline: String; let steps: [Step] }
        let result = try JSONDecoder().decode(Response.self, from: data)
        let points = try decode(result.polyline)
        let steps = try result.steps.map { WalkingStep(instructions: $0.instructions, points: $0.polyline.isEmpty ? [] : try decode($0.polyline, minimumPoints: 1)) }
        return WalkingRoute(provider: .google, points: points, steps: steps, destination: destination)
    }
}
