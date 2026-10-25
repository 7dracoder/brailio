import ARKit
import simd

struct SpatialSurface {
    let transform: simd_float4x4
    let center: SIMD3<Float>
    let extent: SIMD3<Float>
    let supportsObject: Bool
    func intersection(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        guard supportsObject else { return nil }
        let inverse=transform.inverse
        let o=inverse * SIMD4(origin.x,origin.y,origin.z,1), d=inverse * SIMD4(direction.x,direction.y,direction.z,0)
        guard abs(d.y) > 0.001 else { return nil }
        let t = -o.y / d.y
        guard t > 0.15, t < 5 else { return nil }
        let hit=SIMD3(o.x+t*d.x,0,o.z+t*d.z)
        guard abs(hit.x-center.x) <= extent.x/2, abs(hit.z-center.z) <= extent.z/2 else { return nil }
        return origin + t * direction
    }
}
struct SnapshotGeometry {
    let camera: simd_float4x4
    let intrinsics: simd_float3x3
    let resolution: CGSize
    let surfaces: [SpatialSurface]
    func ray(_ point: CGPoint) -> (SIMD3<Float>,SIMD3<Float>)? {
        guard resolution.width > 0, resolution.height > 0, intrinsics[0][0] > 0, intrinsics[1][1] > 0 else { return nil }
        // The displayed scan is the camera image rotated clockwise into portrait.
        let u=Float(point.y * resolution.width), v=Float((1-point.x) * resolution.height)
        let local=SIMD3((u-intrinsics[2][0])/intrinsics[0][0],-(v-intrinsics[2][1])/intrinsics[1][1],-1)
        let world=camera * SIMD4(local.x,local.y,local.z,0)
        let direction=simd_normalize(SIMD3(world.x,world.y,world.z))
        guard [direction.x,direction.y,direction.z].allSatisfy(\.isFinite) else { return nil }
        return (SIMD3(camera.columns.3.x,camera.columns.3.y,camera.columns.3.z),direction)
    }
    func position(_ box: ObjectBox) -> SIMD3<Float>? {
        guard box.valid, let (origin,direction)=ray(CGPoint(x:box.x+box.width/2,y:box.y+box.height/2)) else { return nil }
        return surfaces.compactMap { $0.intersection(origin:origin,direction:direction) }.min { simd_distance($0,origin) < simd_distance($1,origin) }
    }
    static func capture(_ frame: ARFrame) -> Self {
        let surfaces=frame.anchors.compactMap { anchor -> SpatialSurface? in
            guard let plane=anchor as? ARPlaneAnchor else { return nil }
            // Do not silently place an object on a distant floor/wall behind it.
            let supported=plane.classification == .table || plane.classification == .seat
            return SpatialSurface(transform:plane.transform,center:plane.center,extent:plane.extent,supportsObject:supported)
        }
        return Self(camera:frame.camera.transform,intrinsics:frame.camera.intrinsics,resolution:frame.camera.imageResolution,surfaces:surfaces)
    }
    static func depthFeatures(_ frame: ARFrame) -> [SpatialFeature] {
        guard let depth=frame.smoothedSceneDepth ?? frame.sceneDepth else { return [] }
        let buffer=depth.depthMap
        CVPixelBufferLockBaseAddress(buffer,.readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let address=CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let confidence=depth.confidenceMap
        if let confidence { CVPixelBufferLockBaseAddress(confidence,.readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence,.readOnly) } }
        let values=address.assumingMemoryBound(to:Float.self)
        let w=CVPixelBufferGetWidth(buffer), h=CVPixelBufferGetHeight(buffer), stride=CVPixelBufferGetBytesPerRow(buffer)/MemoryLayout<Float>.stride
        let confidenceValues=confidence.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to:UInt8.self) }
        let confidenceStride=confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let k=frame.camera.intrinsics, size=frame.camera.imageResolution
        var result:[SpatialFeature]=[]
        for y in Swift.stride(from:0,to:h,by:max(1,h/20)) {
            for x in Swift.stride(from:0,to:w,by:max(1,w/24)) {
                let z=values[y*stride+x]
                guard z.isFinite, z > 0.15, z < 8 else { continue }
                if let confidenceValues, confidenceValues[y*confidenceStride+x] < 1 { continue }
                let u=Float((Double(x)+0.5)/Double(w)*size.width),v=Float((Double(y)+0.5)/Double(h)*size.height)
                let world=frame.camera.transform * SIMD4((u-k[2][0])/k[0][0]*z,-(v-k[2][1])/k[1][1]*z,-z,1)
                result.append(SpatialFeature(point:SIMD3(world.x,world.y,world.z),image:CGPoint(x:1-(Double(y)+0.5)/Double(h),y:(Double(x)+0.5)/Double(w))))
            }
        }
        return result
    }
}
