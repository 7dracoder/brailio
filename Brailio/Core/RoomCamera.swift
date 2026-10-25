import SwiftUI
import ARKit
import CoreImage
import simd

struct RoomFrame: Equatable {
    let id = UUID()
    let jpeg: Data
    let captured: Date
}
struct SpatialFeature {
    let point: SIMD3<Float>
    let image: CGPoint
}
struct SpatialSnapshot {
    let frame: RoomFrame
    let features: [SpatialFeature]
    var depthFeatures: [SpatialFeature] = []
    var geometry: SnapshotGeometry? = nil
    var worldID:UUID? = nil
    var depth:CapturedDepth? = nil
    func position(in box: ObjectBox) -> SIMD3<Float>? {
        guard box.valid else { return nil }
        let center = CGPoint(x: box.x + box.width / 2, y: box.y + box.height / 2)
        func cluster(_ points:[SpatialFeature], centerLimit:Double) -> SIMD3<Float>? {
            let candidates=points.filter { $0.image.x >= box.x && $0.image.x <= box.x+box.width && $0.image.y >= box.y && $0.image.y <= box.y+box.height }
                .sorted { hypot($0.image.x-center.x,$0.image.y-center.y) < hypot($1.image.x-center.x,$1.image.y-center.y) }
            guard let first=candidates.first, hypot(first.image.x-center.x,first.image.y-center.y) < centerLimit else { return nil }
            let cluster=candidates.prefix(12).filter { simd_distance($0.point,first.point) < 0.25 }
            guard cluster.count >= 3 else { return nil }
            return cluster.reduce(SIMD3<Float>.zero) { $0+$1.point } / Float(cluster.count)
        }
        if let point=cluster(depthFeatures,centerLimit:0.12) { return point }
        if let point=cluster(features,centerLimit:0.15) { return point }
        return geometry?.position(box)
    }
}
struct RoomPin: Codable, Identifiable {
    let id: UUID
    let name: String
    let x: Float
    let y: Float
    let z: Float
    var worldID:UUID? = nil
    var seen:String? = nil
    var date:Date? = nil
    var point: SIMD3<Float> { SIMD3(x,y,z) }
}
enum PinGuidance {
    static func available(age: TimeInterval, normal: Bool, localized: Bool) -> Bool { age >= 0 && age < 2 && normal && localized }
    static func cue(camera: simd_float4x4, target: SIMD3<Float>) -> String? {
        guard [target.x,target.y,target.z].allSatisfy(\.isFinite), camera.determinant.isFinite, abs(camera.determinant) > 0.0001 else { return nil }
        let local = camera.inverse * SIMD4(target.x,target.y,target.z,1)
        if simd_length(SIMD3(local.x, local.y, local.z)) < 0.8 { return "near saved position" }
        if local.z > 0 { return "behind" }
        let angle = atan2(local.x, -local.z)
        return angle < -0.22 ? "left" : angle > 0.22 ? "right" : "ahead"
    }
}

@MainActor final class RoomCamera:NSObject,ObservableObject,@preconcurrency ARSessionDelegate {
    let session=ARSession()
    lazy var trackingView:ARSCNView = { let view=ARSCNView();view.session=session;return view }()
    @Published var running=false
    @Published var recording=false
    @Published var roomFrames:[RoomFrame]=[]
    @Published var scanVersion=0
    @Published var error:String?
    @Published var message="Hold the center to scan. Release, then write an object name."
    @Published var pins:[RoomPin]=[]
    @Published var guiding=false
    @Published var searching=false
    @Published var needsRescan=false
    @Published var feedback=RouteFeedback.paused
    @Published var sessionOnly=true
    @Published private(set) var placementMethod:FindingPlacementMethod?
    private(set) var feedbackRequested=false
    private(set) var worldID=UUID()
    var onFeedback:((RouteFeedback)->Void)?
    var onCue:((Set<Int>)->Void)?
    var onVerdict:((String)->Void)?
    var onStopFeedback:(()->Void)?
    // Testable transport seam; production always uses the real AI client.
    var locate: (String,[SpatialSnapshot]) async throws -> AIResult = { query,views in
        if views.count == 1 { return try await AIClient.request(task:"find",text:query,image:views[0].frame.jpeg) }
        return try await AIClient.request(task:"find_room",text:query,images:views.map { $0.frame.jpeg })
    }
    private var snapshots:[SpatialSnapshot]=[]
    private var target:RoomPin?
    private var query=""
    private var exploring=false
    private var starting=false
    private var startTask:Task<Void,Never>?
    private var operation:Task<Void,Never>?
    private var watchdog:Task<Void,Never>?
    private var generation=UUID()
    private var startedAt=0.0
    private var lastFrameTime=0.0
    private var lastSample=Date.distantPast
    private var scanStarted=Date.distantPast
    private var lastCue=Date.distantPast
    private var recoveryAttempts=0
    private let context=CIContext()
    private var directory:URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("RoomMap") }
    override init() {
        super.init();session.delegate=self;session.delegateQueue = .main
        if let data=try? Data(contentsOf:directory.appendingPathComponent("pins.json")),let saved=try? JSONDecoder().decode([RoomPin].self,from:data) { pins=saved }
        // Names may persist; world coordinates are never trusted after a new AR world.
    }
    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { error="Camera tracking is unavailable in the simulator. Use your iPhone.";return }
        guard !running,!starting else { return };starting=true
        startTask=Task {
            let allowed=await AVCaptureDevice.requestAccess(for:.video)
            guard !Task.isCancelled else { return }
            guard allowed else { starting=false;error="Allow Camera access in iPhone Settings.";return }
            // Faith waits until its AR view is mounted before starting the camera.
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                if trackingView.window != nil { break }
                try? await Task.sleep(for:.milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            guard trackingView.window != nil else { starting=false;error="Camera view is not ready. Reopen Find.";return }
            starting=false;recoveryAttempts=0;runSession(reset:true);startWatchdog()
        }
    }
    private func runSession(reset:Bool) {
        let configuration=ARWorldTrackingConfiguration();configuration.planeDetection=[.horizontal,.vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { configuration.frameSemantics.insert(.smoothedSceneDepth) }
        else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { configuration.frameSemantics.insert(.sceneDepth) }
        startedAt=CACurrentMediaTime();lastFrameTime=0
        session.run(configuration,options:reset ? [.resetTracking,.removeExistingAnchors] : [])
        running=true;error=nil
    }
    private func startWatchdog() {
        watchdog?.cancel();watchdog=Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                guard running else { return }
                if !exploring,feedbackRequested,CACurrentMediaTime()-lastFrameTime>2 { emit(.uncertain) }
                if UIApplication.shared.applicationState == .active,CACurrentMediaTime()-max(lastFrameTime,startedAt)>4 {
                    recoverCamera()
                }
            }
        }
    }
    private func recoverCamera() {
        guard running,recoveryAttempts<3 else { return };recoveryAttempts+=1
        let reset=recoveryAttempts>1
        if reset { invalidateWorld();needsRescan = !query.isEmpty;message="Camera restarted. Tap center to check the current view again." }
        runSession(reset:reset)
    }
    private func invalidateWorld() {
        worldID=UUID();generation=UUID();operation?.cancel();operation=nil
        target=nil;guiding=false;searching=false;snapshots=[];roomFrames=[];placementMethod=nil
    }
    func prepareForScan() {
        stop(); query=""; needsRescan=false; exploring=false
        message="Hold the center to scan. Release, then write an object name."
    }
    func recordRoom() {
        query=""; needsRescan=false
        cancelOperation();feedbackRequested=true;guiding=false;target=nil;snapshots=[];roomFrames=[]
        recording=true;scanStarted=Date();lastSample = .distantPast;exploring=false
        #if DEBUG
        if ProcessInfo.processInfo.environment["BRAILIO_UI_TEST_FIND"] == "1" {
            roomFrames=[RoomFrame(jpeg:Data([0xff,0xd8,0xff,0xd9]),captured:Date())]
            message="Scan fixture active. Release to write.";return
        }
        #endif
        message="Scan slowly. Release to finish.";start();emit(.uncertain)
    }
    func finishRoom() { guard recording else { return };recording=false;scanVersion+=1;message="Scan ready. Write the object name." }
    func stop() {
        feedbackRequested=false;startTask?.cancel();startTask=nil;starting=false;watchdog?.cancel();watchdog=nil
        recording=false;running=false;session.pause();invalidateWorld();emit(.paused);onStopFeedback?()
    }
    func discardRoom() { stop();needsRescan=false;message="Camera stopped. Remembered names remain." }
    func deletePins() { discardRoom();pins=[];try? FileManager.default.removeItem(at:directory) }
    private func cancelOperation() { generation=UUID();operation?.cancel();operation=nil;searching=false }
    func suspendFeedback() { exploring=true;emit(.paused);onStopFeedback?() }
    func resumeFeedback() { guard feedbackRequested else { return };exploring=false;lastCue = .distantPast;if needsRescan || searching { emit(.uncertain) } }
    private func emit(_ value:RouteFeedback) { guard value.kind == .paused || feedbackRequested else { return };feedback=value;onFeedback?(value) }
    private func captureFresh() -> SpatialSnapshot? {
        guard running,lastFrameTime>=startedAt,let frame=session.currentFrame,frame.camera.trackingState == .normal,CACurrentMediaTime()-frame.timestamp<2 else { return nil }
        return copySnapshot(frame)
    }
    private func copySnapshot(_ frame:ARFrame) -> SpatialSnapshot? {
        var image=CIImage(cvPixelBuffer:frame.capturedImage).oriented(.right)
        image=image.transformed(by:CGAffineTransform(translationX:-image.extent.origin.x,y:-image.extent.origin.y))
        let scale=min(1,1024/max(image.extent.width,image.extent.height));image=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let cg=context.createCGImage(image,from:image.extent) else { return nil }
        let ui=UIImage(cgImage:cg)
        guard let data=ui.jpegData(compressionQuality:0.6) else { return nil }
        let jpeg=data.count>260_000 ? ui.jpegData(compressionQuality:0.35) ?? data : data
        guard jpeg.count<=320_000 else { return nil }
        return SpatialSnapshot(frame:RoomFrame(jpeg:jpeg,captured:Date()),features:[],geometry:SnapshotGeometry.capture(frame),worldID:worldID,depth:CapturedDepth.copy(from:frame))
    }
    func find(_ name:String) {
        cancelOperation();feedbackRequested=true;query=name.trimmingCharacters(in:.whitespacesAndNewlines)
        exploring=false;guiding=false;needsRescan=false;target=nil;placementMethod=nil;onStopFeedback?();emit(.uncertain);start()
        guard !query.isEmpty else { message="Write an object name first.";return }
        if let remembered=pins.last(where:{ $0.name.caseInsensitiveCompare(query) == .orderedSame && $0.worldID == worldID }) {
            target=remembered;guiding=true;message="Returning to the position measured in this camera session.";return
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["BRAILIO_UI_TEST_FIND"] == "1" {
            message="Checking a fresh camera view for "+query;return
        }
        #endif
        let lastSeen=pins.last(where:{ $0.name.caseInsensitiveCompare(query) == .orderedSame })?.seen
        searching=true;message=(lastSeen.map { "Last seen: \($0) " } ?? "")+"Checking the current camera view for "+query
        let id=generation,world=worldID,requested=query
        operation=Task {
            for _ in 0..<80 {
                guard id == generation,!Task.isCancelled else { return }
                if let fresh=captureFresh() {
                    await resolve(requested,fresh:fresh,requestID:id,world:world);return
                }
                try? await Task.sleep(for:.milliseconds(100))
            }
            guard id == generation else { return };searching=false;needsRescan=true
            message="Camera is still starting. Move the phone slowly, then tap center to retry.";emit(.uncertain)
        }
    }
    private func resolve(_ requested:String,fresh:SpatialSnapshot,requestID:UUID,world:UUID) async {
        do {
            var evidence=fresh
            var answer=try await locate(requested,[fresh])
            guard requestID == generation,world == worldID,!Task.isCancelled else { return }
            if answer.found != true,!snapshots.isEmpty {
                let views=sampledSnapshots().filter { $0.worldID == world }
                if !views.isEmpty {
                    answer=try await locate(requested,views)
                    guard requestID == generation,world == worldID,!Task.isCancelled else { return }
                    if let i=answer.evidenceFrame,views.indices.contains(i) { evidence=views[i] }
                }
            }
            guard answer.found == true,(answer.confidence ?? 0)>=0.7,let box=answer.box,box.valid else {
                searching=false;needsRescan=true;message="Not seen here. Turn the phone and tap center to search again. The name is kept.";emit(.uncertain);return
            }
            // A later measured surface can place the saved photo's BASE ray. No further model call is needed.
            message="Object seen. Mapping its surface. Move the phone slowly."
            for _ in 0..<40 {
                guard requestID == generation,world == worldID,!Task.isCancelled else { return }
                if let placement=place(box,in:evidence) { saveTarget(requested,placement:placement,seen:answer.text);return }
                try? await Task.sleep(for:.milliseconds(250))
            }
            searching=false;needsRescan=true;message="Object seen but no measured surface yet. Aim at its base and tap center to retry.";emit(.uncertain)
        } catch {
            guard requestID == generation,world == worldID,!Task.isCancelled else { return }
            searching=false;needsRescan=true;message=error.localizedDescription;emit(.uncertain)
        }
    }
    private func place(_ box:ObjectBox,in snapshot:SpatialSnapshot)->FindingPlacement? {
        guard let frame=session.currentFrame,frame.camera.trackingState == .normal,CACurrentMediaTime()-frame.timestamp<2 else { return nil }
        let heights=frame.anchors.compactMap { anchor -> Float? in
            guard let plane=anchor as? ARPlaneAnchor,plane.alignment == .horizontal else { return nil }
            return plane.transform.columns.3.y
        }
        return FaithFinding.place(box,snapshot:snapshot,currentWorld:worldID,planeHeights:heights) { origin,direction,kind in
            let query=ARRaycastQuery(origin:origin,direction:direction,allowing:kind == .existing ? .existingPlaneGeometry : .estimatedPlane,alignment:kind == .existing ? .horizontal : .any)
            guard let result=session.raycast(query).first else { return nil }
            let p=result.worldTransform.columns.3;return SIMD3(p.x,p.y,p.z)
        }
    }
    private func sampledSnapshots()->[SpatialSnapshot] {
        if snapshots.count<=8 { return snapshots };return (0..<8).map { snapshots[Int(Double($0)*Double(snapshots.count-1)/7)] }
    }
    func markCenter(_ name:String) {
        guard let snapshot=captureFresh(),let result=place(ObjectBox(x:0.35,y:0.35,width:0.3,height:0.3),in:snapshot) else { needsRescan=true;message="Point at the surface, move slowly, then try again.";emit(.uncertain);return }
        feedbackRequested=true;saveTarget(name,placement:result)
    }
    private func saveTarget(_ name:String,placement:FindingPlacement,seen:String? = nil) {
        var transform=matrix_identity_float4x4;transform.columns.3=SIMD4(placement.point,1)
        let anchor=ARAnchor(name:name,transform:transform);session.add(anchor:anchor)
        let pin=RoomPin(id:anchor.identifier,name:name,x:placement.point.x,y:placement.point.y,z:placement.point.z,worldID:worldID,seen:seen,date:Date())
        pins.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame };pins.append(pin)
        target=pin;placementMethod=placement.method;guiding=true;searching=false;needsRescan=false;sessionOnly=true;exploring=false;lastCue = .distantPast
        snapshots=[];roomFrames=[];message="Object located in this camera session. Follow the approach taps.";onVerdict?("saved")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if let data=try? JSONEncoder().encode(pins) { try? data.write(to:directory.appendingPathComponent("pins.json"),options:[.atomic,.completeFileProtection]) }
    }
    func check() {
        guard guiding else { if !query.isEmpty { find(query) } else { message="Write an object name first.";onVerdict?("uncertain") };return }
        exploring=true;emit(.paused);onStopFeedback?()
        guard let target,target.worldID == worldID,let frame=session.currentFrame,frame.camera.trackingState == .normal,CACurrentMediaTime()-frame.timestamp<2 else { message="Tracking uncertain. Move slowly.";onVerdict?("uncertain");return }
        let p=frame.camera.transform.columns.3,distance=simd_distance(SIMD3(p.x,p.y,p.z),target.point)
        message=distance<0.8 ? "Near the measured position. Confirm the actual object yourself." : "Not near the measured position yet."
        onVerdict?(distance<0.8 ? "yes" : "no")
    }
    func reject() { feedbackRequested=false;target=nil;guiding=false;emit(.paused);onStopFeedback?();message="Rejected. Turn the phone and search again.";onVerdict?("no") }
    func session(_ session:ARSession,didUpdate frame:ARFrame) {
        guard running,frame.timestamp>=startedAt else { return };lastFrameTime=frame.timestamp
        guard frame.camera.trackingState == .normal else { if feedbackRequested,!exploring { emit(.uncertain) };return }
        if recording,Date().timeIntervalSince(scanStarted)>30 { finishRoom() }
        if recording,Date().timeIntervalSince(lastSample)>=1 {
            lastSample=Date()
            if let sample=copySnapshot(frame) {
                if recording { snapshots.append(sample);roomFrames.append(sample.frame);if snapshots.count>30 { snapshots.removeFirst();roomFrames.removeFirst() } }
            }
        }
        guard feedbackRequested,guiding,!exploring,let target,target.worldID == worldID,Date().timeIntervalSince(lastCue)>=0.05 else { return }
        lastCue=Date();let p=frame.camera.transform.columns.3,distance=Double(simd_distance(SIMD3(p.x,p.y,p.z),target.point))
        let angle=FaithFinding.angle(camera:frame.camera.transform,target:target.point) ?? 0
        message=abs(angle)>90 && distance>0.6 ? "Target behind the phone. Turn slowly. Soft double taps." : "Approach taps get faster and stronger as you get closer. Confirm the object yourself."
        emit(ProximityFeedback.object(distance:distance,angle:angle))
    }
    func sessionWasInterrupted(_ session:ARSession) {
        let requested=feedbackRequested;invalidateWorld();needsRescan = !query.isEmpty;feedbackRequested=requested
        if requested,!exploring { emit(.uncertain) };message="Camera interrupted. Tap center to check a fresh view."
    }
    func sessionInterruptionEnded(_ session:ARSession) { if running { runSession(reset:true) } }
    func session(_ session:ARSession,didFailWithError error:Error) { message="Camera recovering. Move slowly.";if feedbackRequested { emit(.uncertain) };recoverCamera() }
    func sessionShouldAttemptRelocalization(_ session:ARSession)->Bool { false }
}

/// The same AR renderer stays in the window during object-name handwriting.
struct RoomTrackingHost:UIViewRepresentable {
    let room:RoomCamera
    func makeUIView(context:Context)->ARSCNView { room.trackingView }
    func updateUIView(_ view:ARSCNView,context:Context) {}
}
struct RoomHoldPanel:UIViewRepresentable {
    let recording:Bool
    let guiding:Bool
    let canRetry:Bool
    let onHold:()->Void
    let onRelease:()->Void
    let onCheck:()->Void
    func makeUIView(context:Context)->HoldView { HoldView() }
    func updateUIView(_ view:HoldView,context:Context) {
        view.recording=recording;view.canCheck=guiding || canRetry
        view.onHold=onHold;view.onRelease=onRelease;view.onCheck=onCheck
        view.title.text=recording ? "Release to finish" : guiding ? "Tap to check" : canRetry ? "Turn and tap to retry" : "Hold to scan"
        view.accessibilityLabel=view.title.text;view.accessibilityValue=recording ? "Recording" : guiding ? "Guiding" : "Ready";view.accessibilityIdentifier="roomHoldControl"
    }
    final class HoldView:UIView {
        let title=UILabel()
        var recording=false,canCheck=false
        var onHold:(()->Void)?,onRelease:(()->Void)?,onCheck:(()->Void)?
        private var hold:Task<Void,Never>?,held=false
        override init(frame:CGRect) {
            super.init(frame:frame);backgroundColor = .secondarySystemBackground
            title.textAlignment = .center;title.font = .preferredFont(forTextStyle:.title2);title.adjustsFontForContentSizeCategory=true;title.numberOfLines=2
            title.textColor = .white;title.backgroundColor=UIColor(red:0.1,green:0.29,blue:0.24,alpha:0.95);addSubview(title)
            isAccessibilityElement=true;accessibilityTraits = .button;layer.cornerRadius=24;clipsToBounds=true
        }
        required init?(coder:NSCoder) { fatalError() }
        override func layoutSubviews() { super.layoutSubviews();let width=min(bounds.width-32,260);title.frame=CGRect(x:(bounds.width-width)/2,y:(bounds.height-120)/2,width:width,height:120);title.layer.cornerRadius=24;title.clipsToBounds=true }
        override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?) {
            held=false;hold?.cancel();guard touches.first != nil else { return }
            hold=Task { do { try await Task.sleep(for:.milliseconds(450)) } catch { return };held=true;onHold?() }
        }
        override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?) { hold?.cancel();if held { onRelease?() } else if canCheck { onCheck?() } }
        override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?) { hold?.cancel();if held { onRelease?() } }
        override func accessibilityActivate()->Bool { if recording { onRelease?() } else if canCheck { onCheck?() } else { onHold?() };return true }
        deinit { hold?.cancel() }
    }
}
