import Foundation
import WebKit
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Renders the HTML report into a PDF on disk. Uses an offscreen `WKWebView`
/// resized to its content's `scrollHeight` so the result is a single tall
/// page, suitable for screen reading and email/share.
///
/// Why not multi-page? `WKWebView.printOperation(with:)` produces paginated
/// PDFs but requires attaching the view to a window and running a modal
/// print operation — fragile from non-UI code. `createPDF` is async-friendly
/// and works headless. Users who want paginated print output can save the
/// HTML report and use Safari's Cmd-P → Save as PDF.
@MainActor
enum PDFExporter {

    static func write(report: RunReport, to url: URL) async throws {
        let html = HTMLExporter.render(report: report)
        let data = try await renderPDF(html: html)
        try data.write(to: url, options: .atomic)
    }

    static func renderPDF(html: String) async throws -> Data {
        // ~8.5"×11" at 96dpi gives 816×1056pt. Width is fixed at this so the
        // report's CSS (which has max-width: 980 with side margins) lays out
        // similarly to in the HTML preview.
        let pageWidth: CGFloat = 816
        let initialHeight: CGFloat = 1056

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: initialHeight))

        // Hold the delegate alive for the duration of `renderPDF` — WKWebView
        // keeps a *weak* reference to its navigation delegate.
        let coordinator = LoadCoordinator()
        webView.navigationDelegate = coordinator

        webView.loadHTMLString(html, baseURL: nil)
        try await coordinator.waitForLoad()

        // Brief settle so CSS / layout finishes before we measure.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Resize to the content's natural height so the resulting PDF
        // captures everything in one tall page.
        let height = await measureContentHeight(in: webView, fallback: initialHeight)
        let pdfHeight = max(initialHeight, height + 40)
        webView.frame = NSRect(x: 0, y: 0, width: pageWidth, height: pdfHeight)

        // Let the resize settle.
        try? await Task.sleep(nanoseconds: 100_000_000)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            webView.createPDF { result in
                cont.resume(with: result)
            }
        }
    }

    private static func measureContentHeight(in webView: WKWebView,
                                             fallback: CGFloat) async -> CGFloat {
        do {
            let raw = try await webView.evaluateJavaScript("document.body.scrollHeight")
            if let v = raw as? CGFloat { return v }
            if let v = raw as? Double  { return CGFloat(v) }
            if let v = raw as? Int     { return CGFloat(v) }
        } catch {
            // fall through to fallback
        }
        return fallback
    }
}

/// Bridges WKWebView's navigation callbacks to async/await.
@MainActor
private final class LoadCoordinator: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func waitForLoad() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
