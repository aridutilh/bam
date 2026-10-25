import AppKit
import WebKit
import ImageIO

/// SVG is rendered as an image, never as an SVG document. WebKit's image mode
/// disables its scripts and external dependencies; the containing document also
/// has no network access, extensions, credentials or persistent website data.
@MainActor final class FaviconSVGRenderer: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var completion: CheckedContinuation<CGImage?, Never>?
    private var timeout: Task<Void, Never>?
    private var source = ""
    private var maximumDimension = 4096

    nonisolated static func accepts(_ data: Data) -> Bool {
        // Do not hand entity declarations to either XML parser. Only bounded,
        // UTF-8 SVG documents are supported; raster decoding has its own path.
        guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8),
              !text.contains("\0"),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return false }
        let gate = SVGDocumentGate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        parser.delegate = gate
        return parser.parse() && gate.isSVG && gate.depth == 0
    }

    static func render(_ data: Data, maximumDimension: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let renderer = FaviconSVGRenderer()
        return await withTaskCancellationHandler(operation: {
            await renderer.start(data, maximumDimension: maximumDimension)
        }, onCancel: { Task { @MainActor in renderer.finish(nil) } })
    }

    private func start(_ data: Data, maximumDimension: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            completion = continuation
            self.maximumDimension = maximumDimension
            source = "data:image/svg+xml;base64," + data.base64EncodedString()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
            self.web = web; web.navigationDelegate = self
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                self?.finish(nil)
            }
            web.loadHTMLString("<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; base-uri 'none'; form-action 'none'\"></head><body></body></html>", baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard completion != nil, webView === web else { return }
        // Source bytes are arguments, never interpolated into executable code.
        // Image loading preserves emoji, viewBox geometry and SVG font units.
        webView.callAsyncJavaScript(Self.rasterScript,
            arguments: ["source": source, "maximumDimension": maximumDimension], in: nil,
            in: WKContentWorld.world(name: "com.ari.bam.favicon-raster.v1")) { [weak self] result in
                guard let self else { return }
                guard case .success(let value) = result, let string = value as? String,
                      string.hasPrefix("data:image/png;base64,"), string.utf8.count <= 64 * 1024,
                      let data = Data(base64Encoded: String(string.dropFirst(22))),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      image.width == 64, image.height == 64 else { self.finish(nil); return }
                self.finish(image)
            }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }

    private func finish(_ image: CGImage?) {
        guard let completion else { return }
        self.completion = nil; timeout?.cancel(); timeout = nil
        web?.navigationDelegate = nil; web?.stopLoading(); web = nil; source = ""
        completion.resume(returning: image)
    }

    private static let rasterScript = #"""
    const image = new Image();
    await new Promise((resolve, reject) => {
      image.onload = resolve;
      image.onerror = () => reject(new Error('Invalid SVG image'));
      image.src = source;
    });
    const w = image.naturalWidth, h = image.naturalHeight;
    if (!w || !h || w > maximumDimension || h > maximumDimension) return null;
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 64;
    const context = canvas.getContext('2d');
    const scale = Math.min(64 / w, 64 / h);
    context.drawImage(image, (64 - w * scale) / 2, (64 - h * scale) / 2, w * scale, h * scale);
    if (!context.getImageData(0, 0, 64, 64).data.some((v, i) => i % 4 === 3 && v)) return null;
    return canvas.toDataURL('image/png');
    """#
}

private final class SVGDocumentGate: NSObject, XMLParserDelegate {
    var isSVG = false
    var depth = 0
    private var nodes = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if depth == 0 { isSVG = name == "svg" && namespaceURI == "http://www.w3.org/2000/svg" }
        depth += 1; nodes += 1
        if !isSVG || depth > 64 || nodes > 4096 { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
}
