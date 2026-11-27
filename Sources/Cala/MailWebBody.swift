import AppKit
import os
import SwiftUI
import WebKit

struct MailWebBody: View {
    let content: MailContent
    let loadsRemoteImages: Bool
    let onError: (String) -> Void
    @State private var localOnlyRule: WKContentRuleList?

    init(content: MailContent, loadsRemoteImages: Bool, onError: @escaping (String) -> Void) {
        self.content = content
        self.loadsRemoteImages = loadsRemoteImages
        self.onError = onError
        // After prewarm() the rule is already compiled: render on the first pass, no spinner frame.
        _localOnlyRule = State(initialValue: MailWebShared.cachedLocalOnly)
    }

    /// Call once early (mail service start / mail panel appears) so the first message doesn't pay for
    /// the content-rule compile, the data store, the cookie policy or the first WebContent process.
    /// Safe to call repeatedly.
    @MainActor static func prewarm() { MailWebShared.prewarm() }

    var body: some View {
        if loadsRemoteImages || localOnlyRule != nil {
            MailWebPage(document: MailWebDocument(content: content, loadsRemoteImages: loadsRemoteImages),
                        rule: localOnlyRule, onError: onError)
        } else {
            ProgressView().controlSize(.small)
                .accessibilityLabel(tx("Preparing message", "Preparando mensaje"))
                .environment(\.colorScheme, .light)
                .task {
                    do {
                        let rule = try await MailWebShared.localOnly()
                        if !Task.isCancelled { localOnlyRule = rule }
                    } catch {
                        if !Task.isCancelled {
                            onError(tx("Cala couldn’t prepare the image filter.", "Cala no pudo preparar el filtro de imágenes."))
                        }
                    }
                }
        }
    }
}

private struct MailWebDocument {
    let content: MailContent
    let loadsRemoteImages: Bool

    var source: String {
        let imageSources = loadsRemoteImages ? "data: https: http:" : "data:"
        let head = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'">
        <meta name="color-scheme" content="light">
        <style>
          :root { color-scheme: only light !important; background-color: white; color: #202124; }
          body { margin: 12px; }
          .cala-plain-message {
            padding: 12px;
            font: 14px/1.5 Arial, Helvetica, sans-serif;
            white-space: pre-wrap; overflow-wrap: anywhere;
          }
          .cala-plain-message a { color: #1967d2; text-underline-offset: 2px; }
        </style>
        """
        if var html = content.html, let tag = html.range(of: "<head>") {
            // MailContent's sanitizer supplies a complete document with a normalized head tag.
            html.insert(contentsOf: head, at: tag.upperBound)
            return html
        }
        let plainText = content.text.isEmpty ? tx("This message has no text.", "Este mensaje no tiene texto.") : content.text
        let body = "<div class=\"cala-plain-message\">\(Self.linkified(plainText))</div>"
        return """
        <!doctype html>
        <html><head>\(head)</head><body>\(body)</body></html>
        """
    }

    private static func linkified(_ text: String) -> String {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var result = ""
        var previousEnd = 0
        for match in detector?.matches(in: text, range: range) ?? [] {
            guard let url = match.url, canOpen(url) else { continue }
            result += escape(source.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd)))
            result += "<a href=\"\(escape(url.absoluteString))\">\(escape(source.substring(with: match.range)))</a>"
            previousEnd = NSMaxRange(match.range)
        }
        result += escape(source.substring(from: previousEnd))
        return result
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func canOpen(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": true
        default: false
        }
    }
}

private let mailTimingLog = Logger(subsystem: "app.cala", category: "mail-timing")

private func mailMillis(since start: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}

/// Process-wide state shared by every message view: one in-memory data store with cookies
/// disallowed (applied once), the compiled remote-block rule and one warm-up web view.
@MainActor
enum MailWebShared {
    private(set) static var cachedLocalOnly: WKContentRuleList?
    private static var rulesTask: Task<WKContentRuleList, Error>?
    private static var warmView: WKWebView?
    private static var cookiePolicyRequested = false
    private static var cookiePolicyApplied = false
    private static var cookieWaiters: [@MainActor () -> Void] = []

    /// One non-persistent store for all message views: nothing is ever written to disk and
    /// cookies are refused. Only its in-memory cache outlives a message, and it dies with the process.
    static let dataStore: WKWebsiteDataStore = .nonPersistent()

    static func prewarm() {
        applyCookiePolicy()
        guard warmView == nil else { return }
        // Claim the slot now so repeated calls don't build several warm views.
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = dataStore
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        warmView = view
        // Spins up the WebContent process. The page is static, JavaScript is off, nothing is fetched.
        view.loadHTMLString("<!doctype html><meta charset=\"utf-8\"><body></body>", baseURL: nil)
        Task { _ = try? await localOnly() }
    }

    /// Runs `body` once the cookie policy is in place: immediately when it already is.
    static func whenCookiePolicyApplied(_ body: @escaping @MainActor () -> Void) {
        if cookiePolicyApplied { body(); return }
        cookieWaiters.append(body)
        applyCookiePolicy()
    }

    private static func applyCookiePolicy() {
        guard !cookiePolicyRequested else { return }
        cookiePolicyRequested = true
        dataStore.httpCookieStore.setCookiePolicy(.disallow) {
            Task { @MainActor in
                cookiePolicyApplied = true
                let waiters = cookieWaiters
                cookieWaiters = []
                for waiter in waiters { waiter() }
            }
        }
    }

    static func localOnly() async throws -> WKContentRuleList {
        if let cachedLocalOnly { return cachedLocalOnly }
        if let rulesTask { return try await rulesTask.value }
        let task = Task { @MainActor () throws -> WKContentRuleList in
            let id = "cala-mail-block-remote-v1"
            let store = WKContentRuleListStore.default()!
            // Looking up the already-compiled list is far cheaper than compiling it again.
            if let found = try? await store.contentRuleList(forIdentifier: id) { return found }
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            guard let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: rules) else {
                throw CocoaError(.fileReadUnknown)
            }
            return list
        }
        rulesTask = task
        let start = DispatchTime.now()
        do {
            let list = try await task.value
            cachedLocalOnly = list
            mailTimingLog.info("webview-rules \(mailMillis(since: start))ms")
            return list
        } catch {
            rulesTask = nil
            throw error
        }
    }
}

private struct MailWebPage: NSViewRepresentable {
    let document: MailWebDocument
    let rule: WKContentRuleList?
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }

    func makeNSView(context: Context) -> PageView {
        makeView(coordinator: context.coordinator)
    }

    @MainActor
    func makeView(coordinator: Coordinator) -> PageView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = MailWebShared.dataStore
        if let rule { config.userContentController.add(rule) }
        if !document.loadsRemoteImages {
            // The rule and CSP block requests. Render the sender's alt text in the flow
            // so a blocked banner doesn't reserve its original height or show a broken icon.
            let fallback = """
            for (const image of document.querySelectorAll('img[src^="https://" i], img[src^="http://" i]')) {
                const bounds = image.getBoundingClientRect();
                if (!bounds.width || !bounds.height || getComputedStyle(image).visibility !== 'visible') continue;
                const link = image.closest('a[href]');
                let label = image.alt.trim();
                if (!label && bounds.width > 1 && bounds.height > 1 && link &&
                    !link.textContent.trim() && link.querySelectorAll('img').length === 1) {
                    label = link.hostname || link.href;
                }
                if (label) image.before(document.createTextNode(label));
                image.style.setProperty('display', 'none', 'important');
            }
            """
            config.userContentController.addUserScript(WKUserScript(source: fallback, injectionTime: .atDocumentEnd,
                                                                    forMainFrameOnly: true, in: .defaultClient))
        }

        let view = PageView(frame: .zero, configuration: config)
        view.appearance = NSAppearance(named: .aqua)
        view.underPageBackgroundColor = .white
        view.allowsLinkPreview = false
        view.navigationDelegate = coordinator
        view.onLayout = { [weak coordinator] view in coordinator?.fitWidth(view) }
        let source = document.source
        let openedAt = DispatchTime.now()
        MailWebShared.whenCookiePolicyApplied { [weak view, weak coordinator] in
            guard let view, let coordinator, view.navigationDelegate != nil else { return }
            mailTimingLog.info("webview-load start +\(mailMillis(since: openedAt))ms")
            coordinator.loadStart = .now()
            coordinator.documentNavigation = view.loadHTMLString(source, baseURL: nil)
        }
        return view
    }

    func updateNSView(_ view: PageView, context: Context) {
        context.coordinator.onError = onError
    }

    static func dismantleNSView(_ view: PageView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.onLayout = nil
        view.stopLoading()
    }

    final class PageView: WKWebView {
        var onLayout: ((WKWebView) -> Void)?

        override func layout() {
            super.layout()
            onLayout?(self)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onError: (String) -> Void
        var documentNavigation: WKNavigation?
        var loadStart = DispatchTime.now()
        private let openLink: (URL) -> Void
        private var initialLoad = true
        private var finished = false
        private var measuredWidth: CGFloat = 0

        init(onError: @escaping (String) -> Void, openLink: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
            self.onError = onError
            self.openLink = openLink
        }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if initialLoad, action.navigationType == .other, action.targetFrame?.isMainFrame == true,
               url?.absoluteString == "about:blank" {
                initialLoad = false
                return .allow
            }
            if action.navigationType == .linkActivated, let url, MailWebDocument.canOpen(url) {
                openLink(url)
            }
            return .cancel
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
            mailTimingLog.info("webview-didFinish \(mailMillis(since: self.loadStart))ms")
            fitWidth(view)
        }

        func fitWidth(_ view: WKWebView) {
            let width = view.bounds.width
            guard finished, width > 0, width != measuredWidth else { return }
            measuredWidth = width
            view.pageZoom = 1
            // Run Cala's layout query in an isolated world. Scripts in the email stay disabled.
            let query = """
            (() => {
                const root = document.documentElement;
                const body = document.body;
                if (!body || root.scrollWidth <= root.clientWidth) return 1;
                // An overflowing table contributes its far edge to scrollWidth, but
                // WebKit may leave out the body's trailing paper margin.
                const style = getComputedStyle(body);
                const margins = (parseFloat(style.marginLeft) || 0) + (parseFloat(style.marginRight) || 0);
                return root.clientWidth / Math.max(root.scrollWidth, body.scrollWidth + margins);
            })()
            """
            view.evaluateJavaScript(query, in: nil, in: .defaultClient) { [weak view] result in
                guard let view, view.bounds.width == width,
                      case let .success(value) = result,
                      let zoom = value as? CGFloat, zoom > 0, zoom < 1 else { return }
                view.pageZoom = zoom
            }
        }

        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if navigation === documentNavigation { onError(error.localizedDescription) }
        }

        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if navigation === documentNavigation { onError(error.localizedDescription) }
        }

        func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
            onError(tx("The message viewer stopped.", "El visor de mensajes se cerró."))
        }
    }
}
