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

/// Reading/label encoding. Raw navigation and Braille-keyboard cues retain their own patterns.
enum TactileMode: String, CaseIterable {
    case morse, braille
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: "tactileMode") ?? "") ?? .morse }
    var title: String { self == .morse ? "Morse" : "Braille" }
}
enum TactileEncoding {
    static func translate(_ text: String, mode: TactileMode = .current) -> BrailleTranslation {
        mode == .braille ? Braille.translate(text) : Morse.translate(text)
    }
}

/// International Morse timing: mark 1/3 units, element gap 1, letter gap 3, word gap 7.
/// ITU-R M.1677-1. Case is not encoded in Morse.
enum Morse {
    static let codes: [String: String] = Dictionary(uniqueKeysWithValues:
        zip(Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init),
            [".-","-...","-.-.","-..",".","..-.","--.","....","..",".---","-.-",".-..","--","-.","---",".--.","--.-",".-.","...","-","..-","...-",".--","-..-","-.--","--..",
             "-----",".----","..---","...--","....-",".....","-....","--...","---..","----."])
    ).merging([".":".-.-.-",",":"--..--","?":"..--..","'":".----.","!":"-.-.--","/":"-..-.","(":"-.--.",")":"-.--.-","&":".-...",":":"---...",";":"-.-.-.","=":"-...-","+":".-.-.","-":"-....-","_":"..--.-","\"":".-..-.","$":"...-..-","@":".--.-."], uniquingKeysWith: { a, _ in a })
    static func code(_ label: String) -> String { codes[label.lowercased()] ?? "" }
    static func translate(_ text: String) -> BrailleTranslation {
        var cells: [BrailleCell] = [], unsupported: [String] = []
        for character in text {
            let raw = String(character)
            let normalized = raw.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-")
            if character.isWhitespace {
                if cells.last?.label != "Space" { cells.append(BrailleCell(label: "Space", dots: [])) }
            } else if !code(normalized).isEmpty {
                cells.append(BrailleCell(label: normalized, dots: []))
            } else if !unsupported.contains(raw) { unsupported.append(raw) }
        }
        return BrailleTranslation(cells: cells, unsupported: unsupported)
    }
}
struct TactilePulse: Equatable {
    let start: Double
    let duration: Double
}
struct TactileTiming {
    let pulses: [TactilePulse]
    let duration: Double
    static func make(_ cell: BrailleCell, mode: TactileMode, unit: Double) -> Self {
        let unit = unit.isFinite && unit > 0 ? unit : 0.3
        if mode == .braille {
            return Self(pulses: cell.dots.sorted().map { TactilePulse(start: Double($0 - 1) * unit, duration: unit * 0.48) }, duration: unit * 8)
        }
        // Each preceding letter already supplies 3 units: add 4 to make the 7-unit word gap.
        if cell.label == "Space" { return Self(pulses: [], duration: unit * 4) }
        let symbols = Array(Morse.code(cell.label))
        var cursor = 0.0, pulses: [TactilePulse] = []
        for (index, symbol) in symbols.enumerated() {
            let length = symbol == "-" ? 3.0 : 1.0
            pulses.append(TactilePulse(start: cursor * unit, duration: length * unit))
            cursor += length
            if index < symbols.count - 1 { cursor += 1 }
        }
        return Self(pulses: pulses, duration: (cursor + 3) * unit)
    }
}
