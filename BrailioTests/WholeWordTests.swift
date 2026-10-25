import XCTest
import MapKit
@testable import Brailio

final class WholeWordTests:XCTestCase {
    private func line(_ a:CGPoint,_ b:CGPoint)->[CGPoint] { (0...30).map { i in let t=Double(i)/30; return CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t) } }
    private func hat()->[[CGPoint]] {
        let h=[line(CGPoint(x:20,y:30),CGPoint(x:20,y:190)),line(CGPoint(x:100,y:30),CGPoint(x:100,y:190)),line(CGPoint(x:20,y:110),CGPoint(x:100,y:110))]
        let a=[line(CGPoint(x:130,y:190),CGPoint(x:170,y:30))+line(CGPoint(x:170,y:30),CGPoint(x:210,y:190)),line(CGPoint(x:146,y:125),CGPoint(x:194,y:125))]
        let t=[line(CGPoint(x:240,y:30),CGPoint(x:320,y:30)),line(CGPoint(x:280,y:30),CGPoint(x:280,y:190))]
        return h+a+t
    }
    func testWholePrintWordFallbackPreservesGlyphGroups() {
        XCTAssertEqual(InkWordMatcher.groups(hat()).count,3)
        XCTAssertEqual(InkWordMatcher.recognize(hat()),"hat")
    }
    @MainActor func testWholeWordRecognitionPipeline() async {
        let result=await Handwriting.read(hat())
        XCTAssertEqual(result?.lowercased().replacingOccurrences(of:" ",with:""),"hat")
    }
    @MainActor func testPauseKeepsInkUntilExplicitSpaceOrDoneCommit() async {
        let ink=Handwriting(); var committed=""; ink.onRecognized={ committed=$0 }
        let stroke=line(CGPoint(x:30,y:30),CGPoint(x:30,y:180))
        ink.begin(stroke[0]);ink.move(Array(stroke.dropFirst()));ink.lift()
        try? await Task.sleep(for:.milliseconds(1800))
        XCTAssertEqual(committed,"");XCTAssertFalse(ink.strokes.isEmpty)
        ink.finishNow()
        for _ in 0..<50 where committed.isEmpty { try? await Task.sleep(for:.milliseconds(100)) }
        XCTAssertFalse(committed.isEmpty);XCTAssertTrue(ink.strokes.isEmpty)
    }
    func testAmbiguousDestinationsRequireChoiceButNearestIsExplicit() {
        let origin=CLLocation(latitude:37,longitude:-122)
        func item(_ name:String,_ latitude:Double)->MKMapItem { let item=MKMapItem(placemark:MKPlacemark(coordinate:.init(latitude:latitude,longitude:-122)));item.name=name;return item }
        let places=[item("Cafe north",37.01),item("Cafe south",36.999)]
        XCTAssertNil(DestinationResolution.select("cafe",places:places,location:origin))
        XCTAssertEqual(DestinationResolution.select("Cafe north",places:places,location:origin)?.name,"Cafe north")
        XCTAssertEqual(DestinationResolution.select("nearest cafe",places:places,location:origin)?.name,"Cafe south")
    }
    func testBasetenDefaultAndGeminiRemainDistinctProviders() throws {
        let defaults = UserDefaults.standard, old = defaults.object(forKey: "aiProvider")
        defer { if let old { defaults.set(old, forKey: "aiProvider") } else { defaults.removeObject(forKey: "aiProvider") } }
        defaults.removeObject(forKey: "aiProvider"); XCTAssertEqual(DemoAccess.provider, .baseten)
        defaults.set("gemini", forKey: "aiProvider"); XCTAssertEqual(DemoAccess.provider, .gemini)
        let baseten = try DemoBaseten.payload(task: "correct", text: "hello", image: nil, images: [])
        let gemini = try DemoGemini.payload(task: "correct", text: "hello", image: nil, images: [])
        XCTAssertEqual(baseten["model"] as? String, "zai-org/GLM-5.3-Flash")
        XCTAssertNotNil(baseten["messages"]); XCTAssertNotNil(gemini["contents"])
    }
    func testDemoPayloadContainsNoBundledCredentials() throws {
        let payload=try DemoBaseten.payload(task:"correct",text:"helo",image:nil,images:[])
        let data=try JSONSerialization.data(withJSONObject:payload)
        XCTAssertFalse(String(data:data,encoding:.utf8)!.contains("Authorization"))
        XCTAssertThrowsError(try DemoBaseten.payload(task:"find_room",text:"keys",image:nil,images:[]))
    }
}


final class NearbyDestinationTests: XCTestCase {
    private let origin=CLLocation(latitude:37,longitude:-122)
    private func place(_ name:String,metres:Double)->MKMapItem {
        let item=MKMapItem(placemark:MKPlacemark(coordinate:.init(latitude:37+metres/111_000,longitude:-122)));item.name=name;return item
    }
    func testResultsAreNearestFirstEvenIfProviderRanksFarAwayFirst() {
        let values=[place("Far cafe",metres:2000),place("Nearest cafe",metres:100),place("Middle cafe",metres:800)]
        XCTAssertEqual(DestinationResolution.nearby(values,location:origin).map(\.name),["Nearest cafe","Middle cafe","Far cafe"])
    }
    func testFarOnlyOrFarExactMatchNeverStartsAnAutomaticRoute() {
        let far=place("Library",metres:90_000)
        XCTAssertNil(DestinationResolution.select("Library",places:[far],location:origin))
        XCTAssertNil(DestinationResolution.select("nearest library",places:[far],location:origin))
        XCTAssertTrue(DestinationResolution.nearby([far],location:origin).isEmpty)
    }
    func testExpandedResultsStillCannotAutoChooseDistantPlace() {
        let far=place("Clinic",metres:12_000)
        XCTAssertEqual(DestinationResolution.nearby([far],location:origin,radius:20_000).count,1)
        XCTAssertNil(DestinationResolution.select("Clinic",places:[far],location:origin))
    }
    func testNearestRequestChoosesLocalBranchAndShowsDistance() {
        let a=place("Cafe",metres:150),b=place("Cafe",metres:3000)
        XCTAssertTrue(DestinationResolution.select("nearest cafe",places:[b,a],location:origin) === a)
        XCTAssertNil(DestinationResolution.select("Cafe",places:[b,a],location:origin))
        XCTAssertTrue(DestinationResolution.distanceLabel(a,from:origin).contains("metres away"))
        XCTAssertEqual(DestinationResolution.searchText("Nearest Cafe"),"Cafe")
    }
    @MainActor func testLiveNearbySearchOnIPhoneIsBoundedAndDistanceSorted() async throws {
        guard ProcessInfo.processInfo.environment["BRAILIO_LIVE_NEARBY"] == "1" else { throw XCTSkip("Opt-in live local search") }
        let guide=RouteGuide();defer { guide.stop() };guide.enable()
        for _ in 0..<150 {
            if let age=guide.locationAge,age<=6 { break }
            try await Task.sleep(for:.milliseconds(200))
        }
        _ = try XCTUnwrap(guide.location)
        await guide.find("coffee")
        XCTAssertNil(guide.error);XCTAssertFalse(guide.places.isEmpty,guide.status)
        let location=try XCTUnwrap(guide.location)
        let distances=guide.places.map { DestinationResolution.distance($0,from:location) }
        XCTAssertTrue(distances.allSatisfy { $0<=5000 })
        // The phone can move slightly while searching; allow a small tie tolerance.
        XCTAssertTrue(zip(distances,distances.dropFirst()).allSatisfy { $0 <= $1 + 10 })
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:["results":distances.count,"nearestMetres":distances.first ?? -1,"farthestMetres":distances.last ?? -1]),uniformTypeIdentifier:"public.json")
        attachment.name="Nearby-search-distances-no-coordinates";attachment.lifetime = .keepAlways;add(attachment)
    }
}
