import Foundation

struct HapticPulseSpec {
    let intensity: Double
    let times: [Double]
    let duration: Double
    let interval: Double
    static func make(_ feedback: RouteFeedback) -> Self? {
        switch feedback.kind {
        case .paused, .aligned:return nil
        case .uncertain:return Self(intensity:0.35,times:[0,0.3],duration:0.1,interval:3)
        case .deviated:return Self(intensity:max(0,min(1,feedback.strength)),times:[0],duration:0.65,interval:1)
        case .approaching, .end:
            let strength=max(0,min(1,feedback.strength))
            return Self(intensity:strength,times:[0],duration:0.18,interval:1.25-0.65*strength)
        }
    }
}
