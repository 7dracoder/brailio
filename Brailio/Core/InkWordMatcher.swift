import CoreGraphics

/// Print-letter fallback for separate, spatially ordered glyphs. Joined cursive uses native recognition/OCR.
enum InkWordMatcher {
    static func groups(_ strokes: [[CGPoint]]) -> [[[CGPoint]]] {
        let values = strokes.filter { !$0.isEmpty }.sorted { ($0.map(\.x).min() ?? 0) < ($1.map(\.x).min() ?? 0) }
        var groups: [[[CGPoint]]] = []; var right = -Double.infinity
        for stroke in values {
            let left = stroke.map(\.x).min()!, end = stroke.map(\.x).max()!
            if left <= right + 2, !groups.isEmpty { groups[groups.count-1].append(stroke); right = max(right,end) }
            else { groups.append([stroke]); right = end }
        }
        return groups
    }
    static func recognize(_ strokes: [[CGPoint]], digitsOnly: Bool = false) -> String? {
        let groups=groups(strokes)
        guard (2...20).contains(groups.count) else { return InkLetterMatcher.recognize(strokes,digitsOnly:digitsOnly) }
        var result=""
        for group in groups { guard let value=InkLetterMatcher.recognize(group,digitsOnly:digitsOnly) else { return nil }; result += value }
        return result
    }
}
