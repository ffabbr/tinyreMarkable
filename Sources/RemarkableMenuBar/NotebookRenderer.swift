import Foundation
import AppKit
import PDFKit
@preconcurrency import WebKit

/// Renders pure handwritten reMarkable notebooks (collections of v6 .rm stroke files)
/// into a single PDF. Pipeline: rmc → SVG → WKWebView → PDF page → concat.
@MainActor
final class NotebookRenderer {
    static let shared = NotebookRenderer()

    private var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("RemarkableMenuBar", isDirectory: true)
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

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PDFPage?, Error>) in
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
    private let continuation: CheckedContinuation<PDFPage?, Error>
    private let pageSize: NSSize
    private var didFinish = false

    init(webView: WKWebView, continuation: CheckedContinuation<PDFPage?, Error>, pageSize: NSSize) {
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
                    if let pdf = PDFDocument(data: data), let page = pdf.page(at: 0) {
                        self.continuation.resume(returning: page)
                    } else {
                        self.continuation.resume(returning: nil)
                    }
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
