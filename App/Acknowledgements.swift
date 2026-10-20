import AppKit
import OrbitKit

/// The licenses of the packages Orbit ships, in the About panel's credits
/// (D207). `Acknowledgements.txt` is generated: `make acknowledgements`.
@MainActor
enum Acknowledgements {
    static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    /// Label colors, not the black an HTML or RTF credits file is drawn in,
    /// so the text reads in dark mode too.
    private static let credits: NSAttributedString = {
        let result = NSMutableAttributedString()
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return result }
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: TypeScale.caption.rawValue),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: TypeScale.control.rawValue, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        var afterHeading = false
        for line in text.components(separatedBy: "\n") {
            var attributes = body
            var shown = line
            if line.hasPrefix("# ") {
                attributes = heading
                shown = String(line.dropFirst(2))
                afterHeading = true
            } else if afterHeading, let link = line.split(separator: " ").first.flatMap({ URL(string: String($0)) }) {
                // `url · license` under a heading: the address is a link.
                attributes[.link] = link
                afterHeading = false
            }
            result.append(NSAttributedString(string: shown + "\n", attributes: attributes))
        }
        return result
    }()
}
