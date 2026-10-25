import ARKit
import simd

/// Adapted from Faith's snapshot-pose / base-ray / measured-surface placement flow.
/// Reference: 7dracoder/Faith, Finder/Perception/{RayMath,ARSessionController}.swift.
struct CapturedDepth {
    let width: Int
    let height: Int
    let meters: [Float]
    let confidence: [UInt8]
    func distance(sensor: CGPoint) -> Float? {
        guard width > 0, height > 0, meters.count == width*height, confidence.count == meters.count else { return nil }
        let cx=min(width-1,max(0,Int(sensor.x*Double(width)))), cy=min(height-1,max(0,Int(sensor.y*Double(height))))
        var samples:[Float]=[]
        for y in max(0,cy-3)...min(height-1,cy+3) {
            for x in max(0,cx-3)...min(width-1,cx+3) {
                let i=y*width+x,v=meters[i]
                if confidence[i] >= 1 && v.isFinite && (0.1...5).contains(v) { samples.append(v) }
            }
        }
        guard samples.count >= 8 else { return nil }
        samples.sort();return samples[Int(Float(samples.count-1)*0.3)]
    }
    static func copy(from frame: ARFrame) -> Self? {
        guard let depth=frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let buffer=depth.depthMap,w=CVPixelBufferGetWidth(buffer),h=CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride=CVPixelBufferGetBytesPerRow(buffer);var meters:[Float]=[];meters.reserveCapacity(w*h)
        for y in 0..<h { let row=base.advanced(by:y*stride).assumingMemoryBound(to:Float.self);meters.append(contentsOf:UnsafeBufferPointer(start:row,count:w)) }
        var confidence=[UInt8](repeating:1,count:w*h)
        if let map=depth.confidenceMap, CVPixelBufferGetWidth(map) == w, CVPixelBufferGetHeight(map) == h {
            CVPixelBufferLockBaseAddress(map,.readOnly);defer { CVPixelBufferUnlockBaseAddress(map,.readOnly) }
            if let bytes=CVPixelBufferGetBaseAddress(map) { for y in 0..<h {
                let row=bytes.advanced(by:y*CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to:UInt8.self)
                for x in 0..<w { confidence[y*w+x]=row[x] }
            } }
        }
        return Self(width:w,height:h,meters:meters,confidence:confidence)
    }
}
enum FindingPlacementMethod:String { case depth, existingPlane, estimatedPlane, measuredPlane }
struct FindingPlacement { let point:SIMD3<Float>;let method:FindingPlacementMethod }
enum FindingRaycastTarget { case existing, estimated }
enum FaithFinding {
    static func base(of box:ObjectBox)->CGPoint { CGPoint(x:box.x+box.width/2,y:box.y+box.height*0.9) }
    static func place(_ box:ObjectBox, snapshot:SpatialSnapshot, currentWorld:UUID, planeHeights:[Float] = [],
                      raycast:(SIMD3<Float>,SIMD3<Float>,FindingRaycastTarget)->SIMD3<Float>?) -> FindingPlacement? {
        guard box.valid, snapshot.worldID == currentWorld, let geometry=snapshot.geometry else { return nil }
        let center=CGPoint(x:box.x+box.width/2,y:box.y+box.height/2)
        if let depth=snapshot.depth, let z=depth.distance(sensor:CGPoint(x:center.y,y:1-center.x)) {
            let k=geometry.intrinsics,size=geometry.resolution
            guard k[0][0] > 0,k[1][1] > 0 else { return nil }
            let u=Float(center.y*size.width),v=Float((1-center.x)*size.height)
            let world=geometry.camera*SIMD4((u-k[2][0])/k[0][0]*z,-(v-k[2][1])/k[1][1]*z,-z,1)
            let point=SIMD3(world.x,world.y,world.z)
            if valid(point) { return FindingPlacement(point:point,method:.depth) }
        }
        guard let (origin,direction)=geometry.ray(base(of:box)) else { return nil }
        for kind in [FindingRaycastTarget.existing,.estimated] {
            if let point=raycast(origin,direction,kind),valid(point), (0.1...5).contains(simd_distance(origin,point)),simd_dot(point-origin,direction) > 0 {
                return FindingPlacement(point:lift(point,box:box,geometry:geometry),method:kind == .existing ? .existingPlane : .estimatedPlane)
            }
        }
        let surfaceHits=geometry.surfaces.compactMap { $0.intersection(origin:origin,direction:direction) }
        let planeHits=planeHeights.compactMap { horizontalHit(origin:origin,direction:direction,planeY:$0) }
        if let point=(surfaceHits+planeHits).min(by:{ simd_distance(origin,$0)<simd_distance(origin,$1) }),valid(point) {
            return FindingPlacement(point:lift(point,box:box,geometry:geometry),method:.measuredPlane)
        }
        return nil // No fixed-depth or AI-invented distance fallback.
    }
    static func horizontalHit(origin:SIMD3<Float>,direction:SIMD3<Float>,planeY:Float)->SIMD3<Float>? {
        guard abs(direction.y) > 1e-4 else { return nil }
        let t=(planeY-origin.y)/direction.y
        guard t > 0.1, t < 5 else { return nil }
        return origin+direction*t
    }
    private static func valid(_ p:SIMD3<Float>)->Bool { [p.x,p.y,p.z].allSatisfy(\.isFinite) }
    private static func lift(_ point:SIMD3<Float>,box:ObjectBox,geometry:SnapshotGeometry)->SIMD3<Float> {
        let origin=SIMD3(geometry.camera.columns.3.x,geometry.camera.columns.3.y,geometry.camera.columns.3.z)
        let focal=geometry.intrinsics[0][0]
        guard focal > 0 else { return point }
        let size=Float(box.height*geometry.resolution.width)*simd_distance(origin,point)/focal
        var result=point;result.y += min(0.1,max(0.01,size/2));return result
    }
    static func angle(camera:simd_float4x4,target:SIMD3<Float>)->Double? {
        var forward=SIMD3(-camera.columns.2.x,0,-camera.columns.2.z)
        var delta=target-SIMD3(camera.columns.3.x,camera.columns.3.y,camera.columns.3.z);delta.y=0
        guard simd_length(forward)>0.2,simd_length(delta)>0.001 else { return nil }
        forward=simd_normalize(forward);delta=simd_normalize(delta)
        return Double(atan2(-simd_cross(forward,delta).y,simd_dot(forward,delta))*180 / .pi)
    }
}
