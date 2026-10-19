import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI
import WebKit

/// One browser tab's page (D143). The web view lives as long as the tab, so
/// switching tabs keeps the page, its scroll and its state.
@MainActor
@Observable
final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let tabID: String
    @ObservationIgnored let view: WKWebView
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// Why the page didn't load; a dev server still starting is retried.
    private(set) var failure: String?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var retry: Task<Void, Never>?

    init(tabID: String, url: URL) {
        self.tabID = tabID
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // Right-click → Inspect Element opens Safari's Web Inspector.
        view.isInspectable = true
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.navigationDelegate = self
        view.uiDelegate = self
        observations = [
            view.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url ?? self?.url } },
            view.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            view.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            view.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            view.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
        ]
        load(url)
    }

    func load(_ url: URL) {
        retry?.cancel()
        failure = nil
        self.url = url
        view.load(URLRequest(url: url))
    }

    func reload() {
        if failure != nil, let url { return load(url) }
        view.reload()
    }

    func close() {
        retry?.cancel()
        view.stopLoading()
        observations = []
    }

    /// `localhost:3000`, `example.com`, a full URL: what the address field means.
    static func address(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("0.0.0.0") || text.hasPrefix("[::1]") || text.first?.isNumber == true
            text = (local ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text), components.host?.isEmpty == false else { return nil }
        // Servers listening on every interface print 0.0.0.0, which isn't an address to open.
        if components.host == "0.0.0.0" { components.host = "localhost" }
        return components.url
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    private func fail(_ error: any Error) {
        let error = error as NSError
        guard error.code != NSURLErrorCancelled else { return }
        failure = error.localizedDescription
        // A dev server that's still starting: try again for a while.
        guard error.code == NSURLErrorCannotConnectToHost, let url, Self.isLocal(url) else { return }
        retry?.cancel()
        retry = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.failure != nil else { return }
                if await Self.answers(url) { return self.load(url) }
            }
        }
    }

    private static func answers(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    static func isLocal(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host() ?? "") || url.host()?.hasSuffix(".localhost") == true
    }

    // MARK: WKUIDelegate

    /// `target=_blank` and `window.open`: in this tab, not a window of its own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The window's browser tabs, one per server (`localhost:5173`).
@MainActor
final class BrowserStore: WebPreviewing {
    static let kind = "browser"

    private let workspace: Workspace
    private var pages: [String: BrowserPage] = [:]
    /// Opened in this window, newest first, for Open Browser…'s list.
    private(set) var recent: [URL] = []

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func openBrowser(_ url: URL) {
        let host = url.host() ?? url.absoluteString
        let place = url.port.map { "\(host):\($0)" } ?? host
        let tab = EditorTab(id: "browser:\(place)", kind: Self.kind, title: place, systemImage: "globe", url: url)
        recent.removeAll { $0 == url }
        recent.insert(url, at: 0)
        if let page = pages[tab.id] {
            if page.url != url { page.load(url) }
        } else {
            pages[tab.id] = BrowserPage(tabID: tab.id, url: url)
        }
        workspace.open(tab)
    }

    func page(for tab: EditorTab) -> BrowserPage? {
        if let page = pages[tab.id] { return page }
        // A tab restored with the window: its page comes back on first show.
        guard let url = tab.url else { return nil }
        let page = BrowserPage(tabID: tab.id, url: url)
        pages[tab.id] = page
        return page
    }

    /// The tab was closed: its page stops (scripts, sockets, a dev server's live reload).
    func pageDisappeared(_ page: BrowserPage) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !workspace.tabs.contains(where: { $0.id == page.tabID }) else { return }
            page.close()
            pages[page.tabID] = nil
        }
    }

    func closeAll() {
        for page in pages.values { page.close() }
        pages = [:]
    }
}

struct BrowserView: View {
    let page: BrowserPage
    let store: BrowserStore
    @State private var address = ""
    @FocusState private var isEditingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                IconButton("chevron.left", help: "Back") { page.view.goBack() }
                    .disabled(!page.canGoBack)
                IconButton("chevron.right", help: "Forward") { page.view.goForward() }
                    .disabled(!page.canGoForward)
                IconButton(page.isLoading ? "xmark" : "arrow.clockwise", help: page.isLoading ? "Stop" : "Reload") {
                    if page.isLoading { page.view.stopLoading() } else { page.reload() }
                }
                TextField("Address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.orbit(.body))
                    .focused($isEditingAddress)
                    .onSubmit {
                        if let url = BrowserPage.address(address) { page.load(url) } else { NSSound.beep() }
                        isEditingAddress = false
                    }
                    .padding(.horizontal, 4)
                IconButton("safari", help: "Open in Default Browser") {
                    if let url = page.url { NSWorkspace.shared.open(url) }
                }
                .disabled(page.url == nil)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ZStack {
                BrowserHost(page: page)
                if let failure = page.failure {
                    VStack(spacing: 12) {
                        EmptyStateView(
                            "Can't Open the Page", systemImage: "wifi.exclamationmark",
                            message: page.url.map(BrowserPage.isLocal) == true ? "\(failure)\nIs the dev server running? Orbit tries again while it starts." : failure
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { page.reload() }
                            .buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .nativeSurface(.background)
                }
            }
        }
        .onChange(of: page.url, initial: true) {
            if !isEditingAddress { address = page.url?.absoluteString ?? "" }
        }
        .onChange(of: isEditingAddress) { _, editing in
            if !editing { address = page.url?.absoluteString ?? "" }
        }
        .onDisappear { store.pageDisappeared(page) }
    }
}

/// Puts the page's long-lived web view in a container, so SwiftUI rebuilding
/// this never reloads the page.
private struct BrowserHost: NSViewRepresentable {
    let page: BrowserPage

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if page.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        page.view.removeFromSuperview()
        page.view.frame = container.bounds
        page.view.autoresizingMask = [.width, .height]
        container.addSubview(page.view)
    }
}
