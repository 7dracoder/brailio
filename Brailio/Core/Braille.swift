import Foundation

struct BrailleCell: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let dots: Set<Int>
    var glyph: String {
        let value = dots.reduce(0) { $0 | (1 << ($1 - 1)) }
        return String(UnicodeScalar(0x2800 + value)!)
    }
}

struct BrailleTranslation {
    var cells: [BrailleCell]
    var unsupported: [String]
}

/// Deliberately limited English teaching alphabet, not a full UEB transcriber.
enum Braille {
    static let alphabet: [(String, Set<Int>)] = [
        ("a",[1]),("b",[1,2]),("c",[1,4]),("d",[1,4,5]),("e",[1,5]),
        ("f",[1,2,4]),("g",[1,2,4,5]),("h",[1,2,5]),("i",[2,4]),("j",[2,4,5]),
        ("k",[1,3]),("l",[1,2,3]),("m",[1,3,4]),("n",[1,3,4,5]),("o",[1,3,5]),
        ("p",[1,2,3,4]),("q",[1,2,3,4,5]),("r",[1,2,3,5]),("s",[2,3,4]),("t",[2,3,4,5]),
        ("u",[1,3,6]),("v",[1,2,3,6]),("w",[2,4,5,6]),("x",[1,3,4,6]),("y",[1,3,4,5,6]),("z",[1,3,5,6])
    ]
    static let letters = Dictionary(uniqueKeysWithValues: alphabet)
    static let punctuation: [String: Set<Int>] = [",": [2], ";": [2,3], ":": [2,5], ".": [2,5,6], "!": [2,3,5], "?": [2,3,6], "'": [3], "-": [3,6]]
    static func translate(_ text: String) -> BrailleTranslation {
        var cells: [BrailleCell] = []
        var unsupported: [String] = []
        var numeric = false
        for character in text {
            let raw = String(character)
            let normalized = raw.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-")
            if character.isWhitespace {
                cells.append(BrailleCell(label: "Space", dots: [])); numeric = false
            } else if let digit = Int(raw), raw.count == 1, "0123456789".contains(raw) {
                if !numeric { cells.append(BrailleCell(label: "Number sign", dots: [3,4,5,6])) }
                let key = String(Array("jabcdefghi")[digit])
                cells.append(BrailleCell(label: raw, dots: letters[key]!)); numeric = true
            } else if let dots = letters[raw.lowercased()] {
                if numeric && "abcdefghij".contains(raw.lowercased()) {
                    cells.append(BrailleCell(label: "Letter sign", dots: [5,6]))
                }
                if raw != raw.lowercased() { cells.append(BrailleCell(label: "Capital sign", dots: [6])) }
                cells.append(BrailleCell(label: raw, dots: dots)); numeric = false
            } else if let dots = punctuation[normalized] {
                cells.append(BrailleCell(label: normalized, dots: dots)); numeric = false
            } else {
                if !unsupported.contains(raw) { unsupported.append(raw) }
                numeric = false
            }
        }
        return BrailleTranslation(cells: cells, unsupported: unsupported)
    }
}
