import Foundation
import MapKit

struct RouteProjection {
    let distance: Double
    let progress: Double
    let bearing: Double
}
struct RoutePath {
    let points: [CLLocationCoordinate2D]
    let lengths: [Double]
    let cumulative: [Double]
    let total: Double
    init(_ points: [CLLocationCoordinate2D]) {
        self.points = points
        var lengths: [Double] = []; var cumulative = [0.0]
        if points.count > 1 {
            for index in 0..<(points.count - 1) {
                let a = points[index], b = points[index + 1]
                let length = CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                lengths.append(length); cumulative.append(cumulative.last! + length)
            }
        }
        self.lengths = lengths; self.cumulative = cumulative; total = cumulative.last ?? 0
    }
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let lon = (b.longitude - a.longitude) * .pi / 180
        return (atan2(sin(lon) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lon)) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
    static func angle(_ a: Double, _ b: Double) -> Double { abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180) }
    func projection(_ coordinate: CLLocationCoordinate2D, progress: Double) -> RouteProjection? {
        guard points.count >= 2, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let p = MKMapPoint(coordinate); var best: RouteProjection?
        for i in lengths.indices where lengths[i] > 0.2 {
            // Stay near the last matched part of the route: loops and parallel later streets must not steal the match.
            guard cumulative[i] <= progress + 120, cumulative[i + 1] >= progress - 35 else { continue }
            let a = MKMapPoint(points[i]), b = MKMapPoint(points[i + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let raw = ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)
            let low = max(0, (progress - 35 - cumulative[i]) / lengths[i])
            let high = min(1, (progress + 120 - cumulative[i]) / lengths[i])
            guard low <= high else { continue }
            let t = max(low, min(high, raw)); let closest = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = p.distance(to: closest)
            if best == nil || distance < best!.distance { best = RouteProjection(distance: distance, progress: cumulative[i] + lengths[i] * t, bearing: Self.bearing(points[i], points[i + 1])) }
        }
        return best
    }
}
enum RouteFeedbackKind: String { case paused, aligned, approaching, deviated, uncertain, end }
struct RouteFeedback: Equatable {
    let kind: RouteFeedbackKind
    let strength: Double
    static let paused = Self(kind: .paused, strength: 0)
    static let uncertain = Self(kind: .uncertain, strength: 0)
}
struct RouteAssessment {
    let feedback: RouteFeedback
    let progress: Double
    let distance: Double?
    let angle: Double?
}
enum RouteAlignment {
    static func evaluate(_ location: CLLocation, path: RoutePath, progress: Double, now: Date = Date()) -> RouteAssessment {
        let age = now.timeIntervalSince(location.timestamp)
        guard age >= -1, age <= 6, CLLocationCoordinate2DIsValid(location.coordinate), location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 18,
              let projection = path.projection(location.coordinate, progress: progress) else { return RouteAssessment(feedback: .uncertain, progress: progress, distance: nil, angle: nil) }
        let courseValid = location.course.isFinite && (0..<360).contains(location.course) && location.courseAccuracy >= 0 && location.courseAccuracy <= 25 && location.speed >= 0.5 && location.speedAccuracy >= 0 && location.speedAccuracy <= 1.5
        let angle = courseValid ? RoutePath.angle(location.course, projection.bearing) : nil
        let corridor = max(6, location.horizontalAccuracy * 1.5)
        let distanceError = max(0, projection.distance - corridor)
        let distanceSeverity = min(1, distanceError / 35)
        let headingSeverity = angle.map { min(1, max(0, $0 - 30 - location.courseAccuracy) / 60) } ?? 0
        let severity = max(distanceSeverity, headingSeverity)
        let newProgress = projection.distance <= corridor ? max(progress, projection.progress) : progress
        if severity > 0.02 {
            return RouteAssessment(feedback: RouteFeedback(kind: .deviated, strength: min(1, 0.18 + severity * 0.82)), progress: newProgress, distance: projection.distance, angle: angle)
        }
        // A final coordinate is only a nearby checkpoint; it does not confirm a door or a safe arrival.
        if path.total - projection.progress < 8, projection.distance < max(8, location.horizontalAccuracy) {
            return RouteAssessment(feedback: RouteFeedback(kind: .end, strength: 0), progress: newProgress, distance: projection.distance, angle: angle)
        }
        guard courseValid, projection.distance <= 8 else { return RouteAssessment(feedback: .uncertain, progress: newProgress, distance: projection.distance, angle: nil) }
        return RouteAssessment(feedback: RouteFeedback(kind: .aligned, strength: 0), progress: newProgress, distance: projection.distance, angle: angle)
    }
}
struct RouteDeviationFilter {
    private var consecutive = 0
    private var lastStrength = 0.0
    mutating func update(_ feedback: RouteFeedback) -> RouteFeedback {
        guard feedback.kind == .deviated else { consecutive = 0; lastStrength = 0; return feedback }
        consecutive += 1
        guard consecutive >= 2 else { return .uncertain }
        // Decreasing error responds immediately; increasing error eases in after two reliable fixes.
        let strength = lastStrength == 0 ? feedback.strength : min(feedback.strength, lastStrength + 0.2)
        lastStrength = strength
        return RouteFeedback(kind: .deviated, strength: strength)
    }
}
