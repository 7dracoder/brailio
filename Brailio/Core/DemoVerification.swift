#if DEBUG
import UIKit

/// Opt-in synthetic transport check; never records the user's camera or location.
@MainActor enum DemoVerification {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["BRAILIO_VERIFY_DEMO"] == "1" else { return }
        Task {
            var results:[String:Any]=["keyConfigured":DemoAccess.configured]
            do {
                let text=try await AIClient.request(task:"correct",text:"hello")
                results["textPassed"] = !text.text.isEmpty
                let image=UIGraphicsImageRenderer(size:CGSize(width:480,height:480)).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x:0,y:0,width:480,height:480))
                    UIColor.red.setFill(); context.cgContext.fillEllipse(in:CGRect(x:120,y:120,width:240,height:240))
                }
                let result=try await AIClient.request(task:"find_room",text:"red circle",images:[image.jpegData(compressionQuality:0.7)!])
                results["imagePassed"] = result.found == true && result.box?.valid == true && result.evidenceFrame == 0
                results["confidence"] = result.confidence ?? 0
            } catch { results["error"]=error.localizedDescription }
            if let data=try? JSONSerialization.data(withJSONObject:results,options:.sortedKeys) {
                let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try? data.write(to:directory.appendingPathComponent("demo-verification.json"),options:[.atomic,.completeFileProtection])
            }
        }
    }
}
#endif
