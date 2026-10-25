import XCTest
import ARKit
@testable import Brailio

final class ProximityAndSurfaceTests:XCTestCase {
    func testObjectApproachGetsStrongerAndNeverBecomesSilentAtTarget() {
        let values=[10.0,5,2,1,0.3,0].map { ProximityFeedback.object(distance:$0) }
        XCTAssertTrue(values.allSatisfy { $0.kind == .approaching && $0.strength > 0 })
        XCTAssertTrue(zip(values,values.dropFirst()).allSatisfy { $0.strength < $1.strength })
        XCTAssertEqual(values.last?.strength,1)
        XCTAssertEqual(ProximityFeedback.object(distance:.nan).kind,.uncertain)
    }
    func testPulseCadenceGetsFasterAndIsDifferentFromWrongTurnAndUncertainty() throws {
        let far=try XCTUnwrap(HapticPulseSpec.make(ProximityFeedback.object(distance:8)))
        let near=try XCTUnwrap(HapticPulseSpec.make(ProximityFeedback.object(distance:0.2)))
        let error=try XCTUnwrap(HapticPulseSpec.make(RouteFeedback(kind:.deviated,strength:1)))
        let unknown=try XCTUnwrap(HapticPulseSpec.make(.uncertain))
        XCTAssertGreaterThan(near.intensity,far.intensity);XCTAssertLessThan(near.interval,far.interval)
        XCTAssertGreaterThan(error.duration,near.duration);XCTAssertEqual(unknown.times.count,2)
        XCTAssertNil(HapticPulseSpec.make(.paused))
    }
    func testDestinationApproachIncreasesAndEndKeepsPulsing() {
        func assessment(_ progress:Double,_ kind:RouteFeedbackKind = .aligned)->RouteAssessment { RouteAssessment(feedback:RouteFeedback(kind:kind,strength:0),progress:progress,distance:0,angle:0) }
        let far=ProximityFeedback.route(assessment(10),length:500,enabled:true)
        let near=ProximityFeedback.route(assessment(480),length:500,enabled:true)
        let end=ProximityFeedback.route(assessment(498,.end),length:500,enabled:true)
        XCTAssertEqual(far.kind,.approaching);XCTAssertGreaterThan(near.strength,far.strength)
        XCTAssertEqual(end.kind,.end);XCTAssertNotNil(HapticPulseSpec.make(end))
        XCTAssertEqual(ProximityFeedback.route(assessment(10),length:500,enabled:false).kind,.aligned)
    }
    @MainActor func testRouteGuideContinuesAtFinalCheckpointUntilStopped() {
        let guide=RouteGuide()
        let points=[CLLocationCoordinate2D(latitude:37,longitude:-122),CLLocationCoordinate2D(latitude:37.00045,longitude:-122)]
        guide.loadTestRoute(WalkingRoute(provider:.apple,points:points,steps:[],destination:points[1]));guide.start(updatingLocation:false)
        func fix(_ north:Double,_ time:Date)->CLLocation { CLLocation(coordinate:.init(latitude:37+north/111000,longitude:-122),altitude:0,horizontalAccuracy:3,verticalAccuracy:3,course:0,courseAccuracy:5,speed:1.2,speedAccuracy:0.2,timestamp:time) }
        let now=Date()
        guide.ingest(fix(20,now.addingTimeInterval(-1)))
        XCTAssertEqual(guide.feedback.kind,.approaching)
        guide.ingest(fix(47,now))
        XCTAssertTrue(guide.guiding);XCTAssertEqual(guide.feedback.kind,.end)
        guide.stop();XCTAssertFalse(guide.guiding)
    }
    func testClassifiedTableRayCanPositionSmoothObjectWithoutFeaturePoints() throws {
        var camera=matrix_identity_float4x4;camera.columns.3=SIMD4(0,1,1,1)
        let k=simd_float3x3(SIMD3(500,0,0),SIMD3(0,500,0),SIMD3(500,500,1))
        let table=SpatialSurface(transform:matrix_identity_float4x4,center:SIMD3(0,0,-1),extent:SIMD3(4,0,4),supportsObject:true)
        let geometry=SnapshotGeometry(camera:camera,intrinsics:k,resolution:CGSize(width:1000,height:1000),surfaces:[table])
        // In a portrait-rotated image, left-of-center maps below the native camera's optical center.
        let box=ObjectBox(x:0.2,y:0.45,width:0.1,height:0.1)
        let snapshot=SpatialSnapshot(frame:RoomFrame(jpeg:Data(),captured:Date()),features:[],geometry:geometry)
        let point=try XCTUnwrap(snapshot.position(in:box))
        XCTAssertEqual(point.y,0,accuracy:0.001);XCTAssertEqual(point.z,-1,accuracy:0.01)
    }
    func testFaithBaseRayUsesLiveHorizontalPlaneAndNeverGuessesDepth() throws {
        var camera=matrix_identity_float4x4;camera.columns.3=SIMD4(0,1,1,1)
        let k=simd_float3x3(SIMD3(500,0,0),SIMD3(0,500,0),SIMD3(500,500,1))
        let world=UUID()
        let snapshot=SpatialSnapshot(frame:RoomFrame(jpeg:Data(),captured:Date()),features:[],geometry:SnapshotGeometry(camera:camera,intrinsics:k,resolution:CGSize(width:1000,height:1000),surfaces:[]),worldID:world)
        let box=ObjectBox(x:0.1,y:0.45,width:0.1,height:0.1)
        let placed=try XCTUnwrap(FaithFinding.place(box,snapshot:snapshot,currentWorld:world,planeHeights:[0]) { _,_,_ in nil })
        XCTAssertEqual(placed.method,.measuredPlane);XCTAssertLessThan(placed.point.z,1);XCTAssertGreaterThan(placed.point.y,0)
        XCTAssertNil(FaithFinding.place(box,snapshot:snapshot,currentWorld:world) { _,_,_ in nil })
        XCTAssertNil(FaithFinding.place(box,snapshot:snapshot,currentWorld:UUID(),planeHeights:[0]) { _,_,_ in nil })
    }
    func testUnclassifiedOrFloorSurfaceNeverInventsObjectDepth() {
        let floor=SpatialSurface(transform:matrix_identity_float4x4,center:.zero,extent:SIMD3(10,0,10),supportsObject:false)
        XCTAssertNil(floor.intersection(origin:SIMD3(0,1,1),direction:simd_normalize(SIMD3(0,-1,-1))))
        let small=SpatialSurface(transform:matrix_identity_float4x4,center:.zero,extent:SIMD3(0.1,0,0.1),supportsObject:true)
        XCTAssertNil(small.intersection(origin:SIMD3(2,1,2),direction:SIMD3(0,-1,0)))
    }
    @MainActor func testSingleCellCompletionCanResumeFeedbackWithoutAdvancingBook() async {
        let previous=UserDefaults.standard.object(forKey:"slotDuration");UserDefaults.standard.set(0.001,forKey:"slotDuration")
        defer { if let previous { UserDefaults.standard.set(previous,forKey:"slotDuration") } else { UserDefaults.standard.removeObject(forKey:"slotDuration") } }
        let reader=HapticReader();let finished=expectation(description:"Single tactile label completes")
        var bookAdvanced=false;reader.onFinished={ bookAdvanced=true };reader.onSingleFinished={ finished.fulfill() }
        reader.load(Braille.translate("a").cells);reader.play(single:true)
        await fulfillment(of:[finished],timeout:3);XCTAssertFalse(bookAdvanced)
    }
    @MainActor func testStoppedRescanCannotRestartPulsesWhenLabelFinishes() {
        let room=RoomCamera();room.needsRescan=true
        room.stop();room.resumeFeedback()
        XCTAssertFalse(room.feedbackRequested);XCTAssertEqual(room.feedback.kind,.paused)
    }

}


final class CleanFindTests: XCTestCase {
    @MainActor func testFindPanelContainsNoCameraImageView() {
        let panel = RoomHoldPanel.HoldView(frame: .init(x: 0, y: 0, width: 300, height: 500))
        XCTAssertFalse(panel.subviews.contains { $0 is UIImageView })
    }
    @MainActor func testNewScanClearsPriorSearchState() {
        let room = RoomCamera()
        room.message = "Previously looking for laptop"
        room.needsRescan = true
        room.prepareForScan()
        XCTAssertFalse(room.needsRescan); XCTAssertFalse(room.guiding); XCTAssertFalse(room.searching)
        XCTAssertTrue(room.roomFrames.isEmpty)
        XCTAssertFalse(room.message.contains("laptop"))
    }
}

extension CleanFindTests {
    @MainActor func testPhysicalHiddenRoomScanCapturesSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["BRAILIO_LIVE_ROOM_SCAN"] == "1", ARWorldTrackingConfiguration.isSupported else { throw XCTSkip("Opt-in physical camera check") }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw XCTSkip("No foreground window") }
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = UIViewController(), room = RoomCamera()
        window.rootViewController = controller
        room.trackingView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        room.trackingView.alpha = 0.01
        controller.view.addSubview(room.trackingView); window.makeKeyAndVisible()
        defer { room.stop(); window.isHidden = true; previous?.makeKeyAndVisible() }
        room.recordRoom()
        for _ in 0..<150 where room.roomFrames.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(room.running, room.error ?? "Camera did not start")
        guard !room.roomFrames.isEmpty else { throw XCTSkip("Camera started, but needs a textured room view and slow movement to establish tracking") }
        room.finishRoom()
        XCTAssertFalse(room.recording); XCTAssertGreaterThan(room.roomFrames[0].jpeg.count, 100)
        XCTAssertEqual(room.message, "Scan ready. Write the object name.")
    }
    @MainActor func testLiveFindInferenceWithSavedCredential() async throws {
        guard ProcessInfo.processInfo.environment["BRAILIO_LIVE_ROOM_SCAN"] == "1" else { throw XCTSkip("Opt-in live AI check") }
        guard !DemoAccess.key(for: .baseten).isEmpty else { throw XCTSkip("Private iPhone credential is not provisioned") }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 480)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 480, height: 480))
            UIColor.red.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 120, y: 120, width: 240, height: 240))
        }
        let result = try await AIClient.request(task: "find_room", text: "red circle", images: [try XCTUnwrap(image.jpegData(compressionQuality: 0.7))])
        XCTAssertEqual(result.found, true); XCTAssertEqual(result.evidenceFrame, 0); XCTAssertTrue(result.box?.valid == true)
    }
}
