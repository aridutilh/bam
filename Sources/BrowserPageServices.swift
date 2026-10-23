import AppKit
import WebKit

@MainActor extension BrowserController {
    @objc func showDownloads(_ sender: Any?) { downloads.showWindow(relativeTo: view.window) }
    @objc func showHistory(_ sender: Any?) { library.showHistory(relativeTo: view.window) }
    @objc func showArchive(_ sender: Any?) { library.showArchive(relativeTo: view.window) }
    func restoreClosed(_ record: ClosedRecord) {
        var restored: [BrowserTab] = []
        for var tab in record.tabs { tab.id = UUID(); restored.append(tab); session.tabs.append(tab) }
        guard let first = restored.first else { return }
        session.select(first.id)
        if record.split, restored.count == 2 { session.makeSplit(primary: first.id, secondary: restored[1].id) }
        showActive(); save(); view.window?.makeKeyAndOrderFront(nil)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.start(download: download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.start(download: download) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        decisionHandler(attachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.title = "Choose files for \(frame.request.url?.host ?? "this page")"
        panel.canChooseFiles = true; panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}
