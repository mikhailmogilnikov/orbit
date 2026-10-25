import AppKit
import OrbitAPI

/// Asks the file's server what its names are (D201) and hands the ones worth
/// recoloring to the highlighter, after a pause in typing and whenever the
/// server catches up.
@MainActor
final class SemanticTokensController {
    let geometry: DiagnosticsController
    let palette: SyntaxPalette
    weak var languages: LanguageIntelligence?
    var url: URL?
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { refresh() } else { clear() }
        }
    }

    private var request: Task<Void, Never>?
    /// Bumped by every edit: an answer for older text is dropped.
    private var version = 0

    init(geometry: DiagnosticsController, palette: SyntaxPalette) {
        self.geometry = geometry
        self.palette = palette
    }

    func refresh(after delay: Duration = .zero) {
        request?.cancel()
        guard isEnabled, let languages, let url else { return }
        let version = version
        request = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let tokens = await languages.semanticTokens(in: url)
            guard !Task.isCancelled, let self, self.version == version, let tokens else { return }
            palette.semantic = Self.spans(tokens, starts: geometry.lineStarts, length: geometry.length)
        }
    }

    func textDidChange() {
        version += 1
        refresh(after: .milliseconds(400))
    }

    func clear() {
        request?.cancel()
        palette.semantic = []
    }

    nonisolated static func spans(_ tokens: [SemanticToken], starts: [Int], length: Int) -> [SemanticSpan] {
        var spans: [SemanticSpan] = []
        for token in tokens where token.line < starts.count {
            let captures = SemanticColors.captures(for: token.type, modifiers: token.modifiers)
            guard !captures.isEmpty else { continue }
            let lineEnd = token.line + 1 < starts.count ? starts[token.line + 1] : length
            let start = starts[token.line] + token.character
            let end = min(start + token.length, lineEnd, length)
            guard end > start else { continue }
            spans.append(SemanticSpan(range: NSRange(location: start, length: end - start), captures: captures))
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }
}
