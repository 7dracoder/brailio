import Foundation

enum ProximityFeedback {
    static func strength(distance: Double, scale: Double) -> Double? {
        guard distance.isFinite, distance >= 0, scale.isFinite, scale > 0 else { return nil }
        return 0.18 + 0.82 * exp(-distance / scale)
    }
    /// Facing more than 90 degrees away while still out of reach gives soft double taps, as in Faith.
    static func object(distance: Double, angle: Double = 0) -> RouteFeedback {
        guard let value=strength(distance:distance,scale:2) else { return .uncertain }
        if distance > 0.6, abs(angle) > 90 { return .uncertain }
        return RouteFeedback(kind:.approaching,strength:value)
    }
    static func route(_ assessment: RouteAssessment, length: Double, enabled: Bool) -> RouteFeedback {
        guard enabled else { return assessment.feedback }
        switch assessment.feedback.kind {
        case .aligned, .end:
            guard length.isFinite, assessment.progress.isFinite else { return .uncertain }
            guard let value=strength(distance:max(0,length-assessment.progress),scale:100) else { return .uncertain }
            return RouteFeedback(kind:assessment.feedback.kind == .end ? .end : .approaching,strength:value)
        default:return assessment.feedback
        }
    }
}
