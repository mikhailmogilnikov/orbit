import AppKit
import OrbitAPI

/// A color written in the code (`#ff5500`, `rgb(255 85 0 / .5)`, `hsl(20, 100%, 50%)`),
/// shown as a swatch beside the line numbers; clicking it edits it (D149).
struct ColorLiteral: Equatable, Sendable {
    enum Notation: Equatable, Sendable {
        /// Digits written: 3, 4, 6 or 8; uppercase kept.
        case hex(digits: Int, uppercase: Bool)
        /// `rgb` or `rgba`, commas or spaces.
        case rgb(name: String, commas: Bool)
        case hsl(name: String, commas: Bool)
    }

    /// UTF-16 range of the literal in the text.
    var range: NSRange
    var red: Double, green: Double, blue: Double, alpha: Double
    var notation: Notation

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// The color in this literal's own notation.
    func written(_ color: NSColor) -> String {
        let color = color.usingColorSpace(.sRGB) ?? color
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent, a = color.alphaComponent
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        func number(_ value: Double) -> String {
            let rounded = (value * 100).rounded() / 100
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        switch notation {
        case .hex(let digits, let uppercase):
            var hex = String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
            if a < 1 || digits == 4 || digits == 8 { hex += String(format: "%02x", byte(a)) }
            return uppercase ? hex.uppercased() : hex
        case .rgb(let name, let commas):
            let parts = [byte(r), byte(g), byte(b)].map(String.init)
            if commas {
                return a < 1 || name == "rgba" ? "\(name)(\(parts.joined(separator: ", ")), \(number(a)))" : "\(name)(\(parts.joined(separator: ", ")))"
            }
            return "\(name)(\(parts.joined(separator: " "))\(a < 1 ? " / \(number(a))" : ""))"
        case .hsl(let name, let commas):
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            // HSB → HSL.
            let lightness = brightness * (1 - saturation / 2)
            let s = lightness == 0 || lightness == 1 ? 0 : (brightness - lightness) / min(lightness, 1 - lightness)
            let parts = [number(Double(hue * 360)), number(Double(s * 100)) + "%", number(Double(lightness * 100)) + "%"]
            if commas {
                return a < 1 || name == "hsla" ? "\(name)(\(parts.joined(separator: ", ")), \(number(a)))" : "\(name)(\(parts.joined(separator: ", ")))"
            }
            return "\(name)(\(parts.joined(separator: " "))\(a < 1 ? " / \(number(a))" : ""))"
        }
    }
}

enum ColorLiterals {
    // No lookbehind in Swift's regexes: the character before is matched, and the literal is its own group.
    nonisolated(unsafe) static let hex = /(?:^|[^\w&#])(?<literal>#(?<digits>[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4}))(?![\w-])/
    nonisolated(unsafe) static let function = /(?<name>rgba?|hsla?)\(\s*(?<a>-?[\d.]+(?:deg|%)?)\s*(?<sep>,|\s)\s*(?<b>-?[\d.]+%?)\s*[,\s]\s*(?<c>-?[\d.]+%?)\s*(?:[,\/]\s*(?<alpha>[\d.]+%?)\s*)?\)/

    /// Line (0-based) → the first color on it. Issue numbers (`#123`) in prose aren't colors.
    nonisolated static func find(in text: String, prose: Bool) -> [Int: ColorLiteral] {
        var result: [Int: ColorLiteral] = [:]
        var offset = 0
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            defer { offset += line.utf16.count + 1 }
            guard index < 20_000, line.utf16.count < 2000, result.count < 1000, line.contains("#") || line.contains("(") else { continue }
            if let literal = first(in: line, prose: prose) {
                var literal = literal
                literal.range.location += offset
                result[index] = literal
            }
        }
        return result
    }

    nonisolated static func first(in line: Substring, prose: Bool) -> ColorLiteral? {
        var found: [ColorLiteral] = []
        for match in line.matches(of: hex) {
            let digits = String(match.digits)
            if prose, digits.allSatisfy({ $0.isNumber }) { continue }
            guard let literal = parseHex(digits) else { continue }
            found.append(ColorLiteral(range: NSRange(match.literal.startIndex..<match.literal.endIndex, in: line), red: literal.0, green: literal.1, blue: literal.2, alpha: literal.3,
                                      notation: .hex(digits: digits.count, uppercase: digits.contains { $0.isUppercase })))
            break
        }
        for match in line.matches(of: function) {
            let name = String(match.name)
            let commas = match.sep == ","
            let alpha = match.alpha.map(component) ?? 1
            let parsed: (Double, Double, Double)?
            if name.hasPrefix("rgb") {
                parsed = (channel(match.a), channel(match.b), channel(match.c))
            } else {
                parsed = hsl(hue: Double(match.a.replacingOccurrences(of: "deg", with: "")) ?? 0, saturation: component(match.b), lightness: component(match.c))
            }
            guard let parsed else { continue }
            found.append(ColorLiteral(range: NSRange(match.range, in: line), red: parsed.0, green: parsed.1, blue: parsed.2, alpha: alpha,
                                      notation: name.hasPrefix("rgb") ? .rgb(name: name, commas: commas) : .hsl(name: name, commas: commas)))
            break
        }
        return found.min { $0.range.location < $1.range.location }
    }

    private static func parseHex(_ digits: String) -> (Double, Double, Double, Double)? {
        let expanded = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        return (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255, hasAlpha ? Double(value & 0xFF) / 255 : 1)
    }

    /// `255` or `100%` → 0…1.
    private static func channel(_ text: Substring) -> Double {
        text.hasSuffix("%") ? component(text) : min(1, max(0, (Double(text) ?? 0) / 255))
    }

    /// `50%` or `0.5` → 0…1.
    private static func component(_ text: Substring) -> Double {
        let value = text.hasSuffix("%") ? (Double(text.dropLast()) ?? 0) / 100 : Double(text) ?? 0
        return min(1, max(0, value))
    }

    private static func hsl(hue: Double, saturation s: Double, lightness l: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func f(_ n: Double) -> Double {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            return l - s * min(l, 1 - l) * max(-1, min(k - 3, 9 - k, 1))
        }
        return (f(0), f(8), f(4))
    }
}

/// The color panel's target: AppKit keeps it unretained, so it's one object
/// that outlives every editor, pointing at the literal being edited.
@MainActor
final class ColorEditing: NSObject {
    static let shared = ColorEditing()
    private weak var coordinator: CodeEditor.Coordinator?
    private var literal: ColorLiteral?

    func edit(_ literal: ColorLiteral, in coordinator: CodeEditor.Coordinator) {
        self.coordinator = coordinator
        self.literal = literal
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.setTarget(nil)
        panel.color = literal.color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let coordinator, let textView = coordinator.textView as? OrbitTextView, var literal else { return }
        let text = (textView.text ?? "") as NSString
        guard NSMaxRange(literal.range) <= text.length else { return }
        let written = literal.written(panel.color)
        guard written != text.substring(with: literal.range) else { return }
        textView.apply(LineEditing.Edit(range: literal.range, replacement: written, selections: textView.selectionRanges))
        literal.range.length = written.utf16.count
        self.literal = literal
    }
}
