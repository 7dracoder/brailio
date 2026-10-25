import SwiftUI
import UIKit

struct TouchAction: Identifiable {
    let id: String
    let title: String
    var symbol = "circle"
    var value = ""
    var enabled = true
    var selected = false
    let perform: () -> Void
}
private struct DirectFrame: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
private struct TouchFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, value in value }) }
}

/// A fixed surface: pointer exploration never executes an action.
struct TactileSurface<Preview: View>: View {
    let title: String
    let page: String
    let actions: [TouchAction]
    let navigation: [TouchAction]
    let focused: String?
    let onFocus: (String) -> Void
    let onActivate: () -> Void
    var panel: AnyView? = nil
    @ViewBuilder let preview: Preview
    @State private var directFrame: CGRect?
    @State private var frames: [String: CGRect] = [:]
    @AccessibilityFocusState private var accessibilityFocus: String?
    @State private var voiceOver = UIAccessibility.isVoiceOverRunning
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .caption) private var navigationSize = 13
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(.title2, design: .rounded, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(page).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.frame(minHeight: 36)
                preview.frame(maxWidth: .infinity).frame(height: min(100, proxy.size.height * 0.15)).clipped()
                    .accessibilityElement(children: .combine)
                if let panel {
                    panel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(GeometryReader { geometry in Color.clear.preference(key: DirectFrame.self, value: geometry.frame(in: .named("tactileSurface"))) })
                } else {
                VStack(spacing: 10) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 10) {
                            ForEach(0..<2) { column in
                                let index = row * 2 + column
                                if actions.indices.contains(index) { control(actions[index], compact: false) }
                                else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true).allowsHitTesting(false) }
                            }
                        }.frame(maxHeight: .infinity)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 8) {
                    ForEach(navigation) { control($0, compact: true) }
                }.frame(height: max(64, min(86, proxy.size.height * 0.12)))
            }.padding(16).coordinateSpace(name: "tactileSurface")
                .onPreferenceChange(DirectFrame.self) { directFrame = $0 }
                .onPreferenceChange(TouchFrames.self) { frames = $0 }
                .overlay {
                    if !voiceOver {
                        FingerExplorer(frames: frames, directFrame: panel == nil ? nil : directFrame, onFocus: onFocus, onActivate: onActivate).accessibilityHidden(true)
                    }
                }
                .onChange(of: accessibilityFocus) { _, id in if let id { onFocus(id) } }
                .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in voiceOver = UIAccessibility.isVoiceOverRunning }
        }.background(Theme.paper)
    }
    private func control(_ action: TouchAction, compact: Bool) -> some View {
        Button(action: { if action.enabled { action.perform() } }) {
            VStack(spacing: compact ? 6 : 10) {
                if !textSize.isAccessibilitySize || compact {
                    Image(systemName: action.symbol).font(compact ? .system(size: 20, weight: .medium) : .title2).accessibilityHidden(true)
                }
                Text(action.title).font(compact ? .system(size: min(20, navigationSize), weight: .semibold, design: .rounded) : .system(.headline, design: .rounded))
                    .multilineTextAlignment(.center).lineLimit(compact ? 1 : 3).minimumScaleFactor(compact ? 0.85 : 0.65)
                if !compact && !action.value.isEmpty && !textSize.isAccessibilitySize {
                    Text(action.value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(compact ? 6 : 12).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(action.selected ? Color(uiColor: .systemBackground) : Theme.accent)
                .background(action.selected ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: compact ? 18 : 24))
                .overlay { RoundedRectangle(cornerRadius: compact ? 18 : 24).stroke(focused == action.id ? Theme.accent : Theme.border, lineWidth: focused == action.id ? 3 : 1) }
                .clipped()
                .opacity(action.enabled ? 1 : 0.48)
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle()).accessibilityLabel(action.title).accessibilityValue(action.value + (focused == action.id ? " focused" : ""))
            .accessibilityAddTraits(action.selected ? .isSelected : [])
            .accessibilityHint(action.enabled ? "Double tap to activate" : "Unavailable")
            .accessibilityIdentifier(action.id).accessibilityFocused($accessibilityFocus, equals: action.id)
            .background(GeometryReader { geometry in Color.clear.preference(key: TouchFrames.self, value: [action.id: geometry.frame(in: .named("tactileSurface"))]) })
    }
}

private struct FingerExplorer: UIViewRepresentable {
    let frames: [String: CGRect]
    let directFrame: CGRect?
    let onFocus: (String) -> Void
    let onActivate: () -> Void
    func makeUIView(context: Context) -> ExplorerView {
        let view = ExplorerView()
        let tap = UITapGestureRecognizer(target: view, action: #selector(ExplorerView.activate))
        tap.numberOfTapsRequired = 2
        // Delay ordinary taps so a double-tap anywhere cannot change the existing focus.
        tap.delaysTouchesBegan = true; tap.cancelsTouchesInView = true
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: ExplorerView, context: Context) {
        view.frames = frames; view.directFrame = directFrame; view.onFocus = onFocus; view.onActivate = onActivate
    }
    final class ExplorerView: UIView {
        var frames: [String: CGRect] = [:]
        var directFrame: CGRect?
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard !isHidden, isUserInteractionEnabled, bounds.contains(point) else { return false }
            return !(directFrame?.contains(point) ?? false)
        }
        var onFocus: ((String) -> Void)?
        var onActivate: (() -> Void)?
        @objc func activate() { onActivate?() }
        private func explore(_ touches: Set<UITouch>) {
            guard let point = touches.first?.location(in: self), let id = frames.first(where: { $0.value.contains(point) })?.key else { return }
            onFocus?(id)
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { explore(touches) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { explore(touches) }
    }
}
