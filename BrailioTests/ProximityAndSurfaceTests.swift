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
