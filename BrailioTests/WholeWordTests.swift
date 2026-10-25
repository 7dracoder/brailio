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
