import Foundation
import CoreGraphics

/// Conservative shape fallback for isolated print letters when system OCR returns no text.
/// Translation/scale invariant; it deliberately does not rotate a drawing or infer words.
enum InkLetterMatcher {
    struct Template { let text: String; let strokes: [[CGPoint]] }
    private static func path(_ values: [Double]) -> [CGPoint] { stride(from: 0, to: values.count, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) } }
    private static func arc(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double, _ start: Double = 0, _ end: Double = 2 * .pi) -> [CGPoint] {
        (0...40).map { index in let a = start + (end-start) * Double(index)/40; return CGPoint(x:x+rx*cos(a),y:y+ry*sin(a)) }
    }
    static var templates: [Template] {
        let left=path([0,0,0,1]), right=path([1,0,1,1]), top=path([0,0,1,0]), mid=path([0,0.5,1,0.5]), bottom=path([0,1,1,1])
        let c=arc(0.5,0.5,0.5,0.5,-.pi/4,-7 * .pi/4)
        let upperB=arc(0,0.25,0.85,0.25,-.pi/2,.pi/2), lowerB=arc(0,0.75,0.85,0.25,-.pi/2,.pi/2)
        var result: [Template] = [
            Template(text:"a",strokes:[path([0,1,0.5,0,1,1]),path([0.2,0.6,0.8,0.6])]),
            Template(text:"a",strokes:[arc(0.45,0.6,0.4,0.4),path([0.85,0.2,0.85,1])]),
            Template(text:"b",strokes:[left,upperB,lowerB]),
            Template(text:"b",strokes:[left,arc(0.45,0.65,0.45,0.35)]),
            Template(text:"c",strokes:[c]),
            Template(text:"d",strokes:[left,arc(0,0.5,1,0.5,-.pi/2,.pi/2)]),
            Template(text:"d",strokes:[right,arc(0.55,0.65,0.45,0.35)]),
            Template(text:"e",strokes:[left,top,mid,bottom]),
            Template(text:"e",strokes:[path([0,0.5,1,0.5]),arc(0.5,0.5,0.5,0.5,0,1.75 * .pi)]),
            Template(text:"f",strokes:[left,top,mid]),
            Template(text:"g",strokes:[c,path([1,0.5,0.55,0.5,1,0.5,1,0.85])]),
            Template(text:"g",strokes:[arc(0.45,0.35,0.45,0.35),path([0.9,0,0.9,1,0.5,1.15,0.1,1])]),
            Template(text:"h",strokes:[left,right,mid]),
            Template(text:"h",strokes:[left,path([0,0.6,0.35,0.4,0.7,0.5,0.8,1])]),
            Template(text:"i",strokes:[path([0.5,0,0.5,1]),top,bottom]),
            Template(text:"i",strokes:[path([0.5,0.4,0.5,1]),path([0.5,0,0.5,0.02])]),
            Template(text:"j",strokes:[top,path([0.9,0,0.9,0.75,0.75,1,0.25,1,0,0.8])]),
            Template(text:"k",strokes:[left,path([1,0,0,0.5,1,1])]),
            Template(text:"l",strokes:[left,bottom]), Template(text:"l",strokes:[path([0,0,0,1])]),
            Template(text:"m",strokes:[path([0,1,0,0,0.5,0.6,1,0,1,1])]),
            Template(text:"m",strokes:[path([0,1,0,0.3,0.25,0,0.5,0.3,0.5,1,0.5,0.3,0.75,0,1,0.3,1,1])]),
            Template(text:"n",strokes:[path([0,1,0,0,1,1,1,0])]),
            Template(text:"n",strokes:[path([0,1,0,0.3,0.3,0,0.7,0,1,0.3,1,1])]),
            Template(text:"o",strokes:[arc(0.5,0.5,0.5,0.5)]),
            Template(text:"p",strokes:[left,arc(0,0.25,1,0.25,-.pi/2,.pi/2)]),
            Template(text:"q",strokes:[arc(0.5,0.45,0.5,0.45),path([0.65,0.7,1,1.1])]),
            Template(text:"r",strokes:[left,arc(0,0.25,1,0.25,-.pi/2,.pi/2),path([0,0.5,1,1])]),
            Template(text:"r",strokes:[path([0,1,0,0.2,0.3,0,0.7,0.1])]),
            Template(text:"s",strokes:[arc(0.5,0.25,0.5,0.25,-.pi/4,-1.5 * .pi),arc(0.5,0.75,0.5,0.25,-.pi/2,.pi * 0.9)]),
            Template(text:"t",strokes:[top,path([0.5,0,0.5,1])]),
            Template(text:"t",strokes:[path([0.5,0,0.5,1,0.8,1]),path([0.1,0.35,0.9,0.35])]),
            Template(text:"u",strokes:[path([0,0,0,0.7]),arc(0.5,0.7,0.5,0.3,.pi,0),path([1,0.7,1,0])]),
            Template(text:"v",strokes:[path([0,0,0.5,1,1,0])]),
            Template(text:"w",strokes:[path([0,0,0.25,1,0.5,0.4,0.75,1,1,0])]),
            Template(text:"x",strokes:[path([0,0,1,1]),path([1,0,0,1])]),
            Template(text:"y",strokes:[path([0,0,0.5,0.5,1,0]),path([0.5,0.5,0.5,1])]),
            Template(text:"z",strokes:[path([0,0,1,0,0,1,1,1])])
        ]
        // Reversed stroke direction is handled by point-cloud distance; pen lifts can differ.
        result += [Template(text:"0",strokes:[arc(0.5,0.5,0.4,0.5)]),Template(text:"1",strokes:[path([0,0,0,1])]),
                   Template(text:"2",strokes:[path([0,0.2,0.2,0,0.8,0,1,0.2,1,0.4,0,1,1,1])]),
                   Template(text:"3",strokes:[arc(0,0.25,1,0.25,-.pi/2,.pi/2),arc(0,0.75,1,0.25,-.pi/2,.pi/2)]),
                   Template(text:"4",strokes:[path([0.8,1,0.8,0,0,0.65,1,0.65])]),
                   Template(text:"5",strokes:[path([1,0,0,0,0,0.5,0.8,0.5,1,0.7,1,0.9,0.8,1,0,1])]),
                   Template(text:"6",strokes:[path([0.9,0,0.3,0.1,0,0.5,0,0.85]),arc(0.5,0.75,0.5,0.25)]),
                   Template(text:"7",strokes:[path([0,0,1,0,0.2,1])]),
                   Template(text:"8",strokes:[arc(0.5,0.25,0.4,0.25),arc(0.5,0.75,0.5,0.25)]),
                   Template(text:"9",strokes:[arc(0.5,0.25,0.5,0.25),path([1,0.25,1,0.8,0.6,1,0.1,1])])]
        return result
    }
    static func recognize(_ strokes: [[CGPoint]], digitsOnly: Bool = false) -> String? {
        let raw = strokes.flatMap { $0 }
        guard !raw.isEmpty, raw.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let width = (raw.map(\.x).max() ?? 0) - (raw.map(\.x).min() ?? 0)
        let height = (raw.map(\.y).max() ?? 0) - (raw.map(\.y).min() ?? 0)
        guard height > 0.001, width / height < 1.8 else { return nil }
        let points = normalize(strokes)
        guard points.count >= 8 else { return nil }
        var scores: [String: Double] = [:]
        for item in templates where item.text.first!.isNumber == digitsOnly {
            let template = normalize(item.strokes)
            let score = (distance(points, template) + distance(template, points)) / 2
            scores[item.text] = min(scores[item.text] ?? .infinity, score)
        }
        let ranked = scores.sorted { $0.value < $1.value }
        guard let best = ranked.first, best.value < 0.085,
              ranked.count < 2 || ranked[1].value - best.value > 0.008 else { return nil }
        return best.key
    }
    private static func normalize(_ strokes: [[CGPoint]]) -> [CGPoint] {
        var segments: [(CGPoint,CGPoint,Double)] = []
        for stroke in strokes {
            for (a,b) in zip(stroke,stroke.dropFirst()) {
                let length=hypot(b.x-a.x,b.y-a.y)
                if length > 0.001 { segments.append((a,b,length)) }
            }
        }
        let length=segments.reduce(0) { $0+$1.2 }
        guard length>0, let first=strokes.flatMap({$0}).first else { return [] }
        let raw=strokes.flatMap{$0}; let minX=raw.map(\.x).min() ?? first.x; let maxX=raw.map(\.x).max() ?? first.x
        let minY=raw.map(\.y).min() ?? first.y; let maxY=raw.map(\.y).max() ?? first.y
        let scale=max(maxX-minX,maxY-minY); guard scale>0 else{return []}
        let width=max(maxX-minX,scale*0.15), height=max(maxY-minY,scale*0.15)
        var output: [CGPoint]=[]; var index=0; var accumulated=0.0
        for sample in 0..<64 {
            let target=length*Double(sample)/63
            while index<segments.count-1 && accumulated+segments[index].2<target { accumulated+=segments[index].2;index+=1 }
            let (a,b,d)=segments[index];let t=min(1,max(0,(target-accumulated)/d))
            output.append(CGPoint(x:(a.x+(b.x-a.x)*t-(minX+maxX)/2)/width,y:(a.y+(b.y-a.y)*t-(minY+maxY)/2)/height))
        }
        return output
    }
    private static func distance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        guard !b.isEmpty else{return .infinity}
        return a.reduce(0) { sum,p in sum+(b.map{hypot(p.x-$0.x,p.y-$0.y)}.min() ?? 1) }/Double(max(1,a.count))
    }
}
