import SwiftUI

enum Theme {
    static let accent = adaptive(UIColor(red: 0.10, green: 0.29, blue: 0.24, alpha: 1), UIColor(red: 0.70, green: 0.89, blue: 0.77, alpha: 1))
    static let paper = adaptive(UIColor(red: 0.96, green: 0.96, blue: 0.93, alpha: 1), UIColor(red: 0.07, green: 0.09, blue: 0.08, alpha: 1))
    static let surface = adaptive(.white, UIColor(red: 0.11, green: 0.14, blue: 0.12, alpha: 1))
    static let forest = Color(red: 0.10, green: 0.25, blue: 0.21)
    static let lime = Color(red: 0.84, green: 0.94, blue: 0.61)
    static let peach = adaptive(UIColor(red: 0.98, green: 0.88, blue: 0.80, alpha: 1), UIColor(red: 0.29, green: 0.21, blue: 0.17, alpha: 1))
    static let mint = adaptive(UIColor(red: 0.84, green: 0.92, blue: 0.86, alpha: 1), UIColor(red: 0.16, green: 0.25, blue: 0.20, alpha: 1))
    static let lavender = adaptive(UIColor(red: 0.89, green: 0.88, blue: 0.96, alpha: 1), UIColor(red: 0.22, green: 0.20, blue: 0.30, alpha: 1))
    static let border = Color.primary.opacity(0.09)
    static func adaptive(_ light: UIColor, _ dark: UIColor) -> Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light }) }
}

struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased()).font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(Theme.accent)
            Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-0.8).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct SectionTitle: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(.title3, design: .rounded, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct StatusPill: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Theme.mint, in: Capsule()).foregroundStyle(Theme.accent)
            .accessibilityElement(children: .combine)
    }
}
struct InfoNote: View {
    let text: String
    var symbol = "info.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct SecondaryAction: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 10)
                .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
                .overlay { RoundedRectangle(cornerRadius: 15).stroke(Theme.border, lineWidth: 1) }
        }.buttonStyle(PressStyle()).foregroundStyle(Theme.accent).disabled(disabled).opacity(disabled ? 0.45 : 1)
    }
}
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.76 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}
struct BrailleDots: View {
    let dots: Set<Int>
    var active: Int? = nil
    var large = false
    var body: some View {
        HStack(spacing: large ? 22 : 9) {
            ForEach(0..<2) { column in
                VStack(spacing: large ? 14 : 9) {
                    ForEach(1..<4) { row in
                        let dot = column * 3 + row
                        ZStack {
                            Circle().fill(dots.contains(dot) ? Theme.accent : Color.primary.opacity(0.07))
                            if active == dot { Circle().stroke(Theme.accent, lineWidth: 3).padding(-5) }
                            if large { Text("\(dot)").font(.caption.bold()).foregroundStyle(dots.contains(dot) ? Color(uiColor: .systemBackground) : .secondary) }
                        }.frame(width: large ? 38 : 12, height: large ? 38 : 12)
                    }
                }
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(dots.isEmpty ? "Blank Braille cell" : "Braille dots \(dots.sorted().map(String.init).joined(separator: ", "))")
    }
}
struct PrimaryButton: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.headline).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 24).padding(.vertical, 17).padding(.horizontal, 14)
                .background(disabled ? Color(uiColor: .tertiarySystemFill) : Theme.accent, in: RoundedRectangle(cornerRadius: 19))
        }.buttonStyle(PressStyle()).foregroundStyle(disabled ? Color.secondary : Color(uiColor: .systemBackground)).disabled(disabled)
    }
}
struct Card<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 25))
            .overlay { RoundedRectangle(cornerRadius: 25).stroke(contrast == .increased ? Color.primary.opacity(0.5) : Theme.border, lineWidth: 1) }
    }
}
