#if DEBUG
import UIKit
import CoreHaptics

@MainActor enum ProximityVerification {
    static func runIfRequested(using haptics:NavigationHaptics) {
        guard ProcessInfo.processInfo.environment["BRAILIO_VERIFY_PROXIMITY"] == "1" else { return }
        Task {
            for _ in 0..<25 {
                if UIApplication.shared.applicationState == .active { break }
                try? await Task.sleep(for:.milliseconds(200))
            }
            var stages=0
            for distance in [6.0,2,0.2] {
                guard UIApplication.shared.applicationState == .active else { break }
                haptics.update(ProximityFeedback.object(distance:distance))
                try? await Task.sleep(for:.seconds(3))
                guard haptics.error == nil else { break }
                stages += 1
            }
            haptics.stop()
            var report:[String:Any]=["hapticsSupported":CHHapticEngine.capabilitiesForHardware().supportsHaptics,"completedStages":stages,"completed":stages == 3]
            if let error=haptics.error { report["error"]=error }
            let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if let data=try? JSONSerialization.data(withJSONObject:report,options:.sortedKeys) { try? data.write(to:directory.appendingPathComponent("proximity-verification.json"),options:[.atomic,.completeFileProtection]) }
        }
    }
}
#endif
