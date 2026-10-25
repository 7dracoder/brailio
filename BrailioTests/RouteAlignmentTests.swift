import XCTest
import CoreLocation
@testable import Brailio

final class RouteAlignmentTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude:37,longitude:-122)
    private func point(east: Double = 0, north: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude:origin.latitude + north / 111_000, longitude:origin.longitude + east / (111_000 * cos(origin.latitude * .pi / 180)))
    }
    private var path: RoutePath { RoutePath([point(), point(north:500)]) }
    private func fix(east: Double = 0, north: Double = 40, course: Double = 0, accuracy: Double = 3, courseAccuracy: Double = 5, speed: Double = 1.3, at: Date = Date()) -> CLLocation {
        CLLocation(coordinate:point(east:east,north:north),altitude:0,horizontalAccuracy:accuracy,verticalAccuracy:5,course:course,courseAccuracy:courseAccuracy,speed:speed,speedAccuracy:0.3,timestamp:at)
    }
    func testReliableAlignedWalkingIsSilent() {
        let result = RouteAlignment.evaluate(fix(),path:path,progress:30)
        XCTAssertEqual(result.feedback.kind,.aligned); XCTAssertEqual(result.feedback.strength,0)
    }
    func testWrongRightTurnProducesStrongCorrection() {
        let result = RouteAlignment.evaluate(fix(course:90),path:path,progress:40)
        XCTAssertEqual(result.feedback.kind,.deviated); XCTAssertGreaterThan(result.feedback.strength,0.85)
    }
    func testWalkingBackwardsOnRouteProducesStrongCorrection() {
        let result = RouteAlignment.evaluate(fix(course:180),path:path,progress:40)
        XCTAssertEqual(result.feedback.kind,.deviated); XCTAssertGreaterThan(result.feedback.strength,0.95)
    }
    func testCorrectionWeakensMonotonicallyAsUserReturnsThenStops() {
        let strengths = [65.0,35,15,3].map { RouteAlignment.evaluate(fix(east:$0),path:path,progress:40).feedback.strength }
        XCTAssertTrue(zip(strengths,strengths.dropFirst()).allSatisfy { $0 >= $1 }); XCTAssertEqual(strengths.last,0)
        XCTAssertGreaterThan(strengths.first!,0.95)
    }
    func testPoorStaleOrMissingTravelDirectionNeverLooksAligned() {
        for location in [fix(accuracy:40),fix(courseAccuracy:50),fix(speed:0),fix(course:-1),fix(at:Date(timeIntervalSinceNow:-20))] {
            XCTAssertEqual(RouteAlignment.evaluate(location,path:path,progress:40).feedback.kind,.uncertain)
        }
    }
    func testAmbiguousLateralPositionDoesNotClaimAlignment() {
        XCTAssertEqual(RouteAlignment.evaluate(fix(east:15,accuracy:15),path:path,progress:40).feedback.kind,.uncertain)
    }
    func testDeviationRequiresTwoFixesAndRecoveryStopsImmediately() {
        var filter = RouteDeviationFilter()
        XCTAssertEqual(filter.update(RouteFeedback(kind:.deviated,strength:1)).kind,.uncertain)
        XCTAssertEqual(filter.update(RouteFeedback(kind:.deviated,strength:1)).strength,1)
        XCTAssertEqual(filter.update(RouteFeedback(kind:.deviated,strength:0.3)).strength,0.3)
        XCTAssertEqual(filter.update(RouteFeedback(kind:.aligned,strength:0)).strength,0)
        XCTAssertEqual(filter.update(RouteFeedback(kind:.deviated,strength:1)).kind,.uncertain)
    }
    func testRouteBendUsesTheForwardSegmentAfterTheTurn() {
        let path = RoutePath([point(),point(north:60),point(east:100,north:60)])
        let result = RouteAlignment.evaluate(fix(east:20,north:60,course:90),path:path,progress:60)
        XCTAssertEqual(result.feedback.kind,.aligned); XCTAssertGreaterThan(result.progress,70)
    }
    func testRouteMatchCannotJumpToFutureParallelStreet() {
        let route = RoutePath([point(),point(north:500),point(east:10,north:500),point(east:10)])
        let match = route.projection(point(east:10,north:40),progress:30)
        XCTAssertLessThan(match!.progress,150); XCTAssertLessThan(RoutePath.angle(match!.bearing,0),1)
    }
    func testHeadingWrapAndNearbyEnd() {
        XCTAssertEqual(RoutePath.angle(359,1),2)
        let short = RoutePath([point(),point(north:50)])
        XCTAssertEqual(RouteAlignment.evaluate(fix(north:48),path:short,progress:40).feedback.kind,.end)
    }
    @MainActor func testDuplicateGPSCannotConfirmDeviationAndExplorationPausesFeedback() {
        let guide = RouteGuide()
        guide.loadTestRoute(WalkingRoute(provider:.apple,points:path.points,steps:[],destination:point(north:500)))
        var output = RouteFeedback.paused; guide.onFeedback = { output = $0 }
        guide.start(updatingLocation:false)
        let first = fix(course:180,at:Date(timeIntervalSinceNow:-1))
        guide.ingest(first); guide.ingest(first); XCTAssertEqual(output.kind,.uncertain)
        guide.ingest(fix(course:180)); XCTAssertEqual(output.kind,.deviated)
        guide.suspendFeedback(); XCTAssertEqual(output.kind,.paused); XCTAssertTrue(guide.suspended)
        guide.stop(); XCTAssertEqual(output.kind,.paused); XCTAssertFalse(guide.guiding)
    }
    func testGooglePolylineAndURL() throws {
        let points = try GoogleRouting.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(points.count,3); XCTAssertEqual(points[0].latitude,38.5,accuracy:0.00001); XCTAssertEqual(points[2].longitude,-126.453,accuracy:0.00001)
        XCTAssertThrowsError(try GoogleRouting.decode("_p~i")); XCTAssertThrowsError(try GoogleRouting.decode("!!"))
        let url = GoogleRouting.directionsURL(query:"cafe & park")
        let items = URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "destination" }?.value,"cafe & park")
        XCTAssertEqual(items.first { $0.name == "travelmode" }?.value,"walking")
    }
}

extension RouteAlignmentTests {
    func testStationaryPhoneCanUseRecentReliableTrueHeading() {
        let now = Date(), still = fix(speed:0, at:now)
        let aligned = RouteAlignment.evaluate(still,path:path,progress:40,now:now,heading:RouteHeading(degrees:0,accuracy:5,timestamp:now))
        XCTAssertEqual(aligned.feedback.kind,.aligned)
        let away = RouteAlignment.evaluate(still,path:path,progress:40,now:now,heading:RouteHeading(degrees:180,accuracy:5,timestamp:now))
        XCTAssertEqual(away.feedback.kind,.deviated); XCTAssertGreaterThan(away.feedback.strength,0.95)
    }
    func testCompassCannotOverrideStaleGPSOrUnreliableHeading() {
        let now=Date()
        for heading in [RouteHeading(degrees:0,accuracy:40,timestamp:now),RouteHeading(degrees:-1,accuracy:2,timestamp:now),RouteHeading(degrees:0,accuracy:2,timestamp:now.addingTimeInterval(-10))] {
            XCTAssertEqual(RouteAlignment.evaluate(fix(speed:0,at:now),path:path,progress:40,now:now,heading:heading).feedback.kind,.uncertain)
        }
        XCTAssertEqual(RouteAlignment.evaluate(fix(speed:0,at:now.addingTimeInterval(-20)),path:path,progress:40,now:now,heading:RouteHeading(degrees:0,accuracy:2,timestamp:now)).feedback.kind,.uncertain)
    }
    func testMovingCourseTakesPriorityOverPhoneHeading() {
        let now=Date()
        XCTAssertEqual(RouteAlignment.evaluate(fix(course:180,at:now),path:path,progress:40,now:now,heading:RouteHeading(degrees:0,accuracy:2,timestamp:now)).feedback.kind,.deviated)
    }
    @MainActor func testStaleFixRecoversAutomaticallyWhenFreshGPSArrives() {
        let now=Date(), guide=RouteGuide()
        guide.loadTestRoute(WalkingRoute(provider:.apple,points:path.points,steps:[],destination:point(north:500)))
        guide.ingest(fix(at:now.addingTimeInterval(-15)),now:now)
        guide.start(updatingLocation:false); guide.checkLocationFreshness(now:now,recover:false)
        XCTAssertEqual(guide.feedback.kind,.uncertain); XCTAssertTrue(guide.guiding)
        XCTAssertTrue(guide.status.contains("resume automatically"))
        guide.ingest(fix(at:now),now:now)
        XCTAssertEqual(guide.feedback.kind,.approaching); XCTAssertTrue(guide.guiding)
        guide.stop()
    }
    @MainActor func testCompassEventsCannotConfirmCachedLateralGPSDeviation() {
        let now=Date(), guide=RouteGuide()
        guide.loadTestRoute(WalkingRoute(provider:.apple,points:path.points,steps:[],destination:point(north:500)))
        guide.start(updatingLocation:false)
        guide.ingest(fix(east:60,speed:0,at:now),now:now)
        XCTAssertEqual(guide.feedback.kind,.uncertain)
        guide.ingestHeading(RouteHeading(degrees:0,accuracy:3,timestamp:now),now:now)
        guide.ingestHeading(RouteHeading(degrees:0,accuracy:3,timestamp:now.addingTimeInterval(0.1)),now:now.addingTimeInterval(0.1))
        XCTAssertEqual(guide.feedback.kind,.uncertain)
        guide.stop()
    }
    @MainActor func testLiveForegroundLocationStaysFreshWithoutWalking() async throws {
        guard ProcessInfo.processInfo.environment["BRAILIO_LIVE_LOCATION"] == "1" else { throw XCTSkip("Opt-in live iPhone location check") }
        let guide=RouteGuide(); defer { guide.stop() }
        guide.enable()
        for _ in 0..<150 {
            if let age=guide.locationAge, age <= 6 { break }
            try await Task.sleep(for:.milliseconds(200))
        }
        let first=try XCTUnwrap(guide.location,guide.error ?? "No location received")
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(first.timestamp),6)
        var end=first.coordinate; end.latitude += 0.001
        // Synthetic route geometry exercises live sensor refresh without requesting a new personal destination.
        guide.loadTestRoute(WalkingRoute(provider:.apple,points:[first.coordinate,end],steps:[],destination:end))
        guide.start()
        try await Task.sleep(for:.seconds(14))
        XCTAssertGreaterThanOrEqual(guide.locationUpdateCount,2)
        XCTAssertLessThanOrEqual(guide.locationAge ?? .infinity,6)
        let report:[String:Any]=["updates":guide.locationUpdateCount,"fixAgeSeconds":guide.locationAge ?? -1,"accuracyMeters":guide.locationAccuracy ?? -1,"active":guide.guiding,"status":guide.status]
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:report),uniformTypeIdentifier:"public.json"); attachment.name="Live-location-health-no-coordinates"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
