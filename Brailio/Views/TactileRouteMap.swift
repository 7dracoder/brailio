import SwiftUI
import MapKit

struct MapTouchTarget {
    let label: String
    let step: Int?
    let coordinate: CLLocationCoordinate2D
}
struct TactileRouteMap: UIViewRepresentable {
    let route: WalkingRoute
    let location: CLLocation?
    let onExplore: (String) -> Void
    let onSelect: (Int?, String) -> Void
    func makeUIView(context: Context) -> MapView { let view=MapView(); view.map.delegate=view; return view }
    func updateUIView(_ view: MapView, context: Context) {
        view.onExplore=onExplore; view.onSelect=onSelect
        view.configure(route,location:location)
    }
    final class MapView: UIView, MKMapViewDelegate {
        let map=MKMapView()
        let probe=Probe()
        var onExplore: ((String)->Void)?
        var onSelect: ((Int?, String)->Void)?
        private var identity=""
        private var targets: [MapTouchTarget]=[]
        private var targetIndex: Int?
        private var currentLocation=MKPointAnnotation()
        override init(frame:CGRect) {
            super.init(frame:frame); addSubview(map); addSubview(probe)
            map.isScrollEnabled=false; map.isZoomEnabled=false; map.isRotateEnabled=false; map.isPitchEnabled=false
            probe.onPoint={ [weak self] point, force in self?.explore(point,force:force) }
            probe.onActivate={ [weak self] in guard let self, let targetIndex else { return }; onSelect?(targets[targetIndex].step, targets[targetIndex].label) }
            probe.accessibilityIdentifier="tactileRouteMap"; probe.isAccessibilityElement=true
            probe.accessibilityLabel="Apple route map. Touch to feel route points. Double tap to open the focused instruction."
            probe.accessibilityTraits=[.allowsDirectInteraction]
            layer.cornerRadius=24; clipsToBounds=true
        }
        required init?(coder:NSCoder) { fatalError() }
        override func layoutSubviews() { super.layoutSubviews(); map.frame=bounds; probe.frame=bounds }
        func configure(_ route:WalkingRoute,location:CLLocation?) {
            let id="\(route.destination.latitude),\(route.destination.longitude):\(route.points.count)"
            if id != identity {
                identity=id; map.removeOverlays(map.overlays); map.removeAnnotations(map.annotations)
                let line=MKPolyline(coordinates:route.points,count:route.points.count); map.addOverlay(line)
                map.setVisibleMapRect(line.boundingMapRect,edgePadding:UIEdgeInsets(top:45,left:35,bottom:65,right:35),animated:false)
                targets=[]
                if let first=route.points.first { targets.append(MapTouchTarget(label:"Route start",step:nil,coordinate:first)) }
                targets += route.steps.enumerated().compactMap { index,step in step.points.first.map { MapTouchTarget(label:step.instructions,step:index,coordinate:$0) } }
                targets.append(MapTouchTarget(label:"Destination. Confirm the entrance yourself.",step:nil,coordinate:route.destination))
                let destination=MKPointAnnotation(); destination.coordinate=route.destination; destination.title="Destination"; map.addAnnotation(destination)
                currentLocation.title="Your position"; map.addAnnotation(currentLocation)
            }
            if let location { currentLocation.coordinate=location.coordinate }
        }
        private func explore(_ point:CGPoint, force:Bool) {
            guard !targets.isEmpty else { return }
            let index=targets.indices.min { a,b in
                let x=map.convert(targets[a].coordinate,toPointTo:map), y=map.convert(targets[b].coordinate,toPointTo:map)
                return hypot(x.x-point.x,x.y-point.y) < hypot(y.x-point.x,y.y-point.y)
            }!
            guard force || index != targetIndex else { return }; targetIndex=index
            onExplore?("Nearest route point. "+targets[index].label)
        }
        func mapView(_ mapView:MKMapView,rendererFor overlay:MKOverlay)->MKOverlayRenderer {
            let renderer=MKPolylineRenderer(overlay:overlay); renderer.strokeColor = .systemBlue; renderer.lineWidth=7; return renderer
        }
    }
    final class Probe:UIView {
        var onPoint:((CGPoint,Bool)->Void)?
        var onActivate:(()->Void)?
        override init(frame:CGRect) {
            super.init(frame:frame); backgroundColor = .clear
            let explore=UILongPressGestureRecognizer(target:self,action:#selector(exploreTouch(_:)))
            explore.minimumPressDuration=0.12; explore.allowableMovement=10_000; addGestureRecognizer(explore)
            let double=UITapGestureRecognizer(target:self,action:#selector(activate)); double.numberOfTapsRequired=2
            double.require(toFail:explore); addGestureRecognizer(double)
        }
        required init?(coder:NSCoder) { fatalError() }
        @objc private func exploreTouch(_ recognizer:UILongPressGestureRecognizer) {
            if recognizer.state == .began || recognizer.state == .changed { onPoint?(recognizer.location(in:self),recognizer.state == .began) }
        }
        @objc private func activate() { onActivate?() }
        override func accessibilityActivate()->Bool { onActivate?(); return true }
    }
}
