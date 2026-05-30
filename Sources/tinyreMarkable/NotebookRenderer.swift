import Foundation
import AppKit
import PDFKit
@preconcurrency import WebKit

/// Renders pure handwritten reMarkable notebooks (collections of v6 .rm stroke files)
/// into a single PDF. Pipeline: rmc → SVG → WKWebView → PDF page → concat.
@MainActor
final class NotebookRenderer {
    static let shared = NotebookRenderer()

    // reMarkable screen geometry, matching rmc/rmscene's SVG output. The device
    // screen is 1404×1872 px at 226 dpi; rmc emits ink in PDF points (px × 72/226)
    // with x centered at 0 (page middle) and y starting at the top.
    private static let rmScreenW: CGFloat = 1404
    private static let rmScreenH: CGFloat = 1872
    private static let rmScale: CGFloat = 72.0 / 226.0

    private var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("tinyreMarkable", isDirectory: true)
    }
    private var venvDir: URL { appSupportDir.appendingPathComponent("venv", isDirectory: true) }
    private var rmcBinary: URL { venvDir.appendingPathComponent("bin/rmc") }
    private var venvPython: URL { venvDir.appendingPathComponent("bin/python3") }

    /// Render a notebook to PDF. When `pageIndices` is non-nil, only those pages
    /// (indices into `archive.pageUUIDs`) are rendered, in the order given — this
    /// avoids rendering the whole notebook when the caller wants just a few pages.
    func render(archive: RMArchive, to outURL: URL, pageIndices: [Int]? = nil, progress: @escaping (String) -> Void) async throws {
        try await ensureRendererInstalled(progress: progress)

        let workDir = archive.directory.appendingPathComponent("svg-out", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Which pages to render (indices into archive.pageUUIDs).
        let targets = pageIndices ?? Array(archive.pageUUIDs.indices)
        let total = targets.count

        // Render pages concurrently. The heavy work per page — the `rmc` subprocess
        // and the WKWebView → PDF conversion — runs off the main thread (or async),
        // so overlapping several pages is a real speedup. Results are gathered by
        // index and assembled in order afterwards.
        let maxConcurrent = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
        var pages = [PDFPage?](repeating: nil, count: total)
        var completed = 0

        try await withThrowingTaskGroup(of: (Int, PDFPage?).self) { group in
            // `slot` is the output position; targets[slot] is the page index in the archive.
            func addTask(_ slot: Int) {
                let pageUUID = archive.pageUUIDs[targets[slot]]
                let rm = archive.rmFile(for: pageUUID)
                group.addTask { [self] in
                    try await (slot, renderOnePage(pageUUID: pageUUID, rm: rm, workDir: workDir))
                }
            }

            var next = 0
            while next < min(maxConcurrent, total) { addTask(next); next += 1 }

            for try await (i, page) in group {
                try Task.checkCancellation()
                pages[i] = page
                completed += 1
                progress("Rendered \(completed) of \(total) pages…")
                if next < total { addTask(next); next += 1 }
            }
        }

        let outDoc = PDFDocument()
        var insertIndex = 0
        for page in pages {
            guard let page else { continue }
            outDoc.insert(page, at: insertIndex)
            insertIndex += 1
        }

        guard outDoc.pageCount > 0 else {
            throw NSError(domain: "NotebookRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No pages rendered from notebook."])
        }
        guard outDoc.write(to: outURL) else {
            throw NSError(domain: "NotebookRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to write rendered PDF."])
        }
    }

    /// Composite handwritten annotations onto an embedded source PDF. For each
    /// requested page the original PDF page is drawn first, then the page's `.rm`
    /// ink (rendered via rmc → SVG → PDF) is overlaid, scaled and positioned to
    /// match how the reMarkable fit the PDF onto its screen. Pages without ink are
    /// copied through unchanged. `pageIndices == nil` means every page.
    func compositeAnnotatedPDF(archive: RMArchive, sourcePDF: URL, to outURL: URL, pageIndices: [Int]? = nil, progress: @escaping (String) -> Void) async throws {
        try await ensureRendererInstalled(progress: progress)

        guard let srcDoc = PDFDocument(url: sourcePDF) else {
            throw NSError(domain: "NotebookRenderer", code: 20, userInfo: [NSLocalizedDescriptionKey: "Could not open the source PDF."])
        }
        let workDir = archive.directory.appendingPathComponent("svg-out", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let targets = pageIndices ?? Array(archive.pageUUIDs.indices)
        let total = targets.count

        guard let consumer = CGDataConsumer(url: outURL as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw NSError(domain: "NotebookRenderer", code: 21, userInfo: [NSLocalizedDescriptionKey: "Could not create the output PDF."])
        }

        var completed = 0
        for pageIndex in targets {
            try Task.checkCancellation()
            guard pageIndex >= 0, pageIndex < srcDoc.pageCount, let srcPage = srcDoc.page(at: pageIndex) else { continue }

            // Page size as shown on the device (rotation-adjusted).
            let bounds = srcPage.bounds(for: .mediaBox)
            let rotated = abs(srcPage.rotation % 180) == 90
            let pageW = rotated ? bounds.height : bounds.width
            let pageH = rotated ? bounds.width : bounds.height

            var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
            ctx.beginPage(mediaBox: &mediaBox)

            // 1) The original PDF page (vector, rotation-aware).
            srcPage.draw(with: .mediaBox, to: ctx)

            // 2) The handwritten ink for this page, if any.
            let pageUUID = pageIndex < archive.pageUUIDs.count ? archive.pageUUIDs[pageIndex] : nil
            if let pageUUID, let rm = archive.rmFile(for: pageUUID) {
                let svg = workDir.appendingPathComponent("\(pageUUID).svg")
                try await runRmc(input: rm, output: svg)
                if let overlayData = try await renderSVGToPDFData(svgURL: svg),
                   let overlayDoc = CGPDFDocument(CGDataProvider(data: overlayData as CFData)!),
                   let overlayPage = overlayDoc.page(at: 1),
                   let viewBox = svgViewBox(svg) {
                    let t = Self.annotationTransform(viewBox: viewBox,
                                                     overlaySize: overlayPage.getBoxRect(.mediaBox).size,
                                                     pageW: pageW, pageH: pageH,
                                                     landscape: archive.isLandscape)
                    ctx.saveGState()
                    // The overlay has a white background; multiply makes white vanish
                    // while keeping the ink, so the PDF beneath shows through.
                    ctx.setBlendMode(.multiply)
                    ctx.concatenate(t)
                    ctx.drawPDFPage(overlayPage)
                    ctx.restoreGState()
                }
            }

            ctx.endPage()
            completed += 1
            progress("Rendered \(completed) of \(total) pages…")
        }

        ctx.closePDF()

        guard completed > 0 else {
            throw NSError(domain: "NotebookRenderer", code: 22, userInfo: [NSLocalizedDescriptionKey: "No pages produced from the annotated PDF."])
        }
    }

    /// The SVG's `viewBox` as a rect (origin = absolute min x/y in points, plus size).
    /// rmc always emits at least the full screen, so this locates the ink in page space.
    private func svgViewBox(_ svgURL: URL) -> CGRect? {
        guard let data = try? Data(contentsOf: svgURL),
              let svg = String(data: data, encoding: .utf8),
              let vb = firstAttr("viewBox", in: svg) else { return nil }
        let parts = vb.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// Affine transform mapping the rmc-rendered ink overlay onto the source PDF page,
    /// reproducing how the reMarkable lays the document out on its screen.
    ///
    /// rmc emits ink in PDF points in the device's *portrait* frame: x centered at 0
    /// (page middle), y from the top, the full screen being `canvasW × canvasH`. The
    /// overlay PDF page spans the SVG `viewBox`, so overlay point `(ox, oy)` (y-up,
    /// origin bottom-left) corresponds to device point
    ///   u = viewBox.minX + ox,  v = (viewBox.minY + height) − oy   (v measured from top).
    ///
    /// The device frame maps onto the page differently per orientation:
    /// - **Portrait**: the page is fit to the screen *width* (`pageW / canvasW`) and
    ///   anchored top-left; the page is generally taller than one screen and scrolls.
    /// - **Landscape**: the page is rotated 90° clockwise, its width fit to the screen's
    ///   *long* axis (`pageW / canvasH`) and centered on the short axis.
    ///
    /// Each step is affine, so we compose them by mapping three overlay basis points.
    static func annotationTransform(viewBox: CGRect, overlaySize: CGSize,
                                    pageW: CGFloat, pageH: CGFloat,
                                    landscape: Bool) -> CGAffineTransform {
        let canvasW = rmScreenW * rmScale
        let canvasH = rmScreenH * rmScale
        let overlayTop = viewBox.minY + overlaySize.height

        // overlay (ox, oy) → source-PDF point (y-up).
        func map(_ ox: CGFloat, _ oy: CGFloat) -> CGPoint {
            let u = viewBox.minX + ox          // device x, centered at 0
            let v = overlayTop - oy            // device y, from the top
            let px: CGFloat, pyt: CGFloat      // page point, y from the top
            if landscape {
                let s = pageW / canvasH
                px = pageW / 2 - (v - canvasH / 2) * s
                pyt = pageH / 2 + u * s
            } else {
                let s = pageW / canvasW
                px = (u + canvasW / 2) * s
                pyt = v * s
            }
            return CGPoint(x: px, y: pageH - pyt)
        }

        let o = map(0, 0), x = map(1, 0), y = map(0, 1)
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y,
                                 c: y.x - o.x, d: y.y - o.y,
                                 tx: o.x, ty: o.y)
    }

    // MARK: - Renderer setup

    private func ensureRendererInstalled(progress: @escaping (String) -> Void) async throws {
        if FileManager.default.fileExists(atPath: rmcBinary.path) { return }

        progress("Setting up notebook renderer (one-time, ~30s)…")
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        let python = try findSystemPython()
        // Create venv
        try await runProcess(python, args: ["-m", "venv", venvDir.path])
        // Upgrade pip silently
        try await runProcess(venvPython, args: ["-m", "pip", "install", "--quiet", "--upgrade", "pip"])
        // Install rmc
        try await runProcess(venvPython, args: ["-m", "pip", "install", "--quiet", "rmc"])

        guard FileManager.default.fileExists(atPath: rmcBinary.path) else {
            throw NSError(domain: "NotebookRenderer", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Could not install the notebook renderer (rmc) into \(venvDir.path)."
            ])
        }
    }

    private func findSystemPython() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3",
        ]
        for c in candidates {
            let url = URL(fileURLWithPath: c)
            guard FileManager.default.fileExists(atPath: c) else { continue }
            if let v = try? pythonVersion(url), v.major == 3, v.minor >= 10 {
                return url
            }
        }
        throw NSError(domain: "NotebookRenderer", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "Python 3.10+ is required to render handwritten notebooks. Install it (e.g. `brew install python@3.12`) and try again."
        ])
    }

    private func pythonVersion(_ url: URL) throws -> (major: Int, minor: Int) {
        let p = Process()
        p.executableURL = url
        p.arguments = ["-c", "import sys;print(f\"{sys.version_info.major}.{sys.version_info.minor}\")"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let str = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = str.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return (0, 0) }
        return (parts[0], parts[1])
    }

    // MARK: - rmc + process helpers

    private func runRmc(input: URL, output: URL) async throws {
        try await runProcess(rmcBinary, args: ["-t", "svg", input.path, "-o", output.path])
    }

    /// Render a single notebook page: .rm → SVG (rmc) → PDF page (WKWebView).
    /// Returns a blank page when the page has no strokes or produced no output.
    private func renderOnePage(pageUUID: String, rm: URL?, workDir: URL) async throws -> PDFPage? {
        if let rm {
            let svg = workDir.appendingPathComponent("\(pageUUID).svg")
            try await runRmc(input: rm, output: svg)
            if let page = try await renderSVGToPDFPage(svgURL: svg) {
                return page
            }
        }
        return blankPage()
    }

    @discardableResult
    private func runProcess(_ executable: URL, args: [String]) async throws -> String {
        let (status, outData, errData) = try await runProcessCancellable { p in
            p.executableURL = executable
            p.arguments = args
        }
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        if status != 0 {
            throw NSError(domain: "NotebookRenderer", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "\(executable.lastPathComponent) failed:\n\(errStr.isEmpty ? outStr : errStr)"
            ])
        }
        return outStr
    }

    // MARK: - SVG → PDF

    private func blankPage() -> PDFPage? {
        // reMarkable 2 page (1404 × 1872 px). In PDF points (72 dpi) that's roughly 595 × 793,
        // matching A4 dimensions — convenient.
        let pageSize = NSSize(width: 595, height: 793)
        let img = NSImage(size: pageSize)
        img.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: pageSize)).fill()
        img.unlockFocus()
        return PDFPage(image: img)
    }

    private func renderSVGToPDFPage(svgURL: URL) async throws -> PDFPage? {
        guard let data = try await renderSVGToPDFData(svgURL: svgURL) else { return nil }
        return PDFDocument(data: data)?.page(at: 0)
    }

    /// Render an SVG to a one-page PDF and return its raw data. Used by the annotated-PDF
    /// compositor, which needs the data to back a `CGPDFDocument` it keeps alive while
    /// drawing (a bare `PDFPage` whose document has been freed can't be drawn reliably).
    private func renderSVGToPDFData(svgURL: URL) async throws -> Data? {
        let svgData = try Data(contentsOf: svgURL)
        guard let svgString = String(data: svgData, encoding: .utf8) else { return nil }

        // Wrap the SVG in a tiny HTML doc so WKWebView lays it out cleanly.
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:0;background:white;}
          svg{width:100%;height:auto;display:block;}
        </style></head><body>\(svgString)</body></html>
        """

        // Use the SVG's viewBox to size the WKWebView so the whole drawing fits the PDF page.
        let (width, height) = svgViewBoxDimensions(svgString) ?? (595, 793)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            let frame = NSRect(x: 0, y: 0, width: width, height: height)
            let config = WKWebViewConfiguration()
            let webView = WKWebView(frame: frame, configuration: config)
            // Hold a strong reference until finished.
            let bridge = WebViewBridge(webView: webView, continuation: cont, pageSize: NSSize(width: width, height: height))
            webView.navigationDelegate = bridge
            objc_setAssociatedObject(webView, &WebViewBridge.key, bridge, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func svgViewBoxDimensions(_ svg: String) -> (CGFloat, CGFloat)? {
        // Try explicit width/height attributes first.
        if let w = firstAttr("width", in: svg), let h = firstAttr("height", in: svg) {
            if let wn = Double(w), let hn = Double(h) {
                return (CGFloat(wn), CGFloat(hn))
            }
        }
        if let viewBox = firstAttr("viewBox", in: svg) {
            let parts = viewBox.split(separator: " ").compactMap { Double($0) }
            if parts.count == 4 { return (CGFloat(parts[2]), CGFloat(parts[3])) }
        }
        return nil
    }

    private func firstAttr(_ name: String, in svg: String) -> String? {
        // Match e.g. width="123.4" — first occurrence only.
        let pattern = "\\b\(name)=\"([^\"]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(svg.startIndex..<svg.endIndex, in: svg)
        guard let m = re.firstMatch(in: svg, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: svg) else { return nil }
        return String(svg[r])
    }
}

@MainActor
private final class WebViewBridge: NSObject, WKNavigationDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    private let webView: WKWebView
    private let continuation: CheckedContinuation<Data?, Error>
    private let pageSize: NSSize
    private var didFinish = false

    init(webView: WKWebView, continuation: CheckedContinuation<Data?, Error>, pageSize: NSSize) {
        self.webView = webView
        self.continuation = continuation
        self.pageSize = pageSize
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didFinish else { return }
        didFinish = true
        // Brief delay so layout settles before snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            let config = WKPDFConfiguration()
            config.rect = NSRect(origin: .zero, size: pageSize)
            webView.createPDF(configuration: config) { result in
                switch result {
                case .success(let data):
                    self.continuation.resume(returning: data)
                case .failure(let err):
                    self.continuation.resume(throwing: err)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !didFinish else { return }
        didFinish = true
        continuation.resume(throwing: error)
    }
}
