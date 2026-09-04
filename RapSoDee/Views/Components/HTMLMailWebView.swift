import SwiftUI
import AppKit
import WebKit

/// Sandboxed HTML mail renderer — JavaScript off, non-persistent data store.
struct HTMLMailWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let wrapped = Self.wrap(html)
        if context.coordinator.lastHTML == wrapped { return }
        context.coordinator.lastHTML = wrapped
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    static func wrap(_ html: String) -> String {
        let css = """
        html, body { margin: 0; padding: 0; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-size: 14px;
          line-height: 1.45;
          color: #1d1d1f;
          word-wrap: break-word;
          overflow-wrap: anywhere;
          max-width: 100%;
        }
        img, table { max-width: 100%; height: auto; }
        a { color: #1F8A5B; }
        pre, code { white-space: pre-wrap; word-break: break-word; }
        """
        let lower = html.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).lowercased()
        if lower.contains("<html") {
            if html.range(of: "</head>", options: .caseInsensitive) != nil {
                return html.replacingOccurrences(
                    of: "</head>",
                    with: "<style>\(css)</style></head>",
                    options: .caseInsensitive,
                    range: nil
                )
            }
            return html
        }
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        </head><body>\(html)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
