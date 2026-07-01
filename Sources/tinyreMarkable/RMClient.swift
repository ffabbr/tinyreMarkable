import Foundation
import Combine
import PDFKit

/// A downloaded, unzipped document ready to be turned into PDF pages — but not yet
/// rendered. Lets callers learn the page count cheaply and render only the pages they
/// need (handwritten notebooks are expensive to render per page).
struct PreparedDocument {
    enum Source {
        /// Plain uploaded PDF (no handwriting): a complete PDF already exists on disk.
        case embeddedPDF(URL)
        /// Uploaded PDF with handwritten annotations on top: the source PDF plus the
        /// archive's per-page `.rm` strokes, which must be rendered and composited.
        case annotatedPDF(pdf: URL, archive: RMArchive)
        /// Pure handwritten notebook: pages must be rendered on demand.
        case notebook(RMArchive)
    }
    let source: Source
    let pageCount: Int
    let name: String
}

enum RMError: LocalizedError {
    case binaryDownloadFailed(detail: String)
    case offline
    case authExpired
    case notebookNotRenderable(name: String)
    case notFound(path: String)
    case rmapiFailed(stderr: String)
    case notAuthenticated
    case pairingCodeInvalid
    case pairingFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .binaryDownloadFailed(let detail):
            return "Couldn’t download the reMarkable cloud helper (rmapi). Check your internet connection and try again.\n\n\(detail)"
        case .offline:
            return "No internet connection. Connect to the internet and try again."
        case .authExpired:
            return "Your reMarkable session has expired. Open the reMarkable desktop app to sign in again, then retry."
        case .notebookNotRenderable(let name):
            return "“\(name)” couldn’t be rendered to PDF — its handwriting data is in a format this app can’t process. Workaround: open it in the reMarkable desktop app and use File → Export."
        case .notFound(let path):
            return "Could not find “\(path)” on your reMarkable."
        case .rmapiFailed(let stderr):
            return "Something went wrong:\n\n\(Self.shortenStderr(stderr))"
        case .notAuthenticated:
            return "Not signed in to reMarkable cloud."
        case .pairingCodeInvalid:
            return "The one-time code must be 8 characters. Get a fresh code at my.remarkable.com and try again."
        case .pairingFailed(let detail):
            return "Couldn’t pair with the reMarkable cloud.\n\n\(detail)"
        }
    }

    /// Map the raw rmapi stderr/stdout into a friendly error.
    static func from(rmapiOutput output: String) -> RMError {
        let lower = output.lowercased()
        // Network failures, in all the phrasings Go's net stack / macOS resolver emit
        // when there's no connectivity. Checked first because rmapi's token refresh
        // fails the same way offline as it does with a dead token, and we don't want
        // to misreport "no internet" as "session expired".
        let offlineMarkers = [
            "no such host",
            "dial tcp",
            "network is unreachable",
            "network is down",
            "no route to host",
            "connection refused",
            "connection reset",
            "i/o timeout",
            "operation timed out",
            "timeout exceeded",
            "context deadline exceeded",
            "tls handshake",
            "server misbehaving",
            "nodename nor servname",      // macOS getaddrinfo, no DNS
            "name resolution",
            "could not resolve",
            "temporary failure",
            "lookup ",                    // DNS lookup failures: "lookup <host>: ..."
        ]
        if offlineMarkers.contains(where: lower.contains) {
            return .offline
        }
        // A *definitive* auth signal means the session is genuinely dead. A bare
        // "failed to create user token" without one of these is almost always the
        // offline case above (the refresh couldn't reach the server), so don't
        // treat it as expiry on its own.
        if lower.contains("unauthorized")
            || lower.contains("401")
            || lower.contains("403")
            || lower.contains("token is expired")
            || lower.contains("invalid token")
            || lower.contains("invalid grant") {
            return .authExpired
        }
        if lower.contains("does not contain a unique pagedata")
            || lower.contains("failed to generate annotations") {
            return .notebookNotRenderable(name: "this document")
        }
        if lower.contains("entry doesn't exist") || lower.contains("not found") {
            return .notFound(path: "the requested item")
        }
        return .rmapiFailed(stderr: output)
    }

    private static func shortenStderr(_ s: String) -> String {
        // Strip rmapi log timestamps like "ERROR: 2026/05/22 17:11:14 transport.go:258:" and trim.
        let pattern = #"(?m)^(ERROR|WARN|INFO|DEBUG):\s*\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+\S+:\s*"#
        let cleaned = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        let lines = cleaned.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let dedup = Array(NSOrderedSet(array: lines)) as? [String] ?? lines
        return dedup.prefix(3).joined(separator: "\n")
    }
}

/// Wraps a Process so a task-cancellation handler can terminate it from another thread.
private final class CancellableProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }
}

/// Run a configured process to completion off the main thread, terminating it if the
/// surrounding Task is cancelled. Throws `CancellationError` when cancelled.
@discardableResult
func runProcessCancellable(input: String? = nil, configure: @escaping @Sendable (Process) -> Void) async throws -> (status: Int32, out: Data, err: Data) {
    let cp = CancellableProcess()
    return try await withTaskCancellationHandler {
        try await Task.detached {
            let p = cp.process
            configure(p)
            let outPipe = Pipe(); let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            let inPipe = Pipe()
            p.standardInput = input != nil ? inPipe : FileHandle.nullDevice

            try p.run()
            if let input {
                try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
            // Read before waiting so a large output can't deadlock the pipe.
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            p.waitUntilExit()
            if cp.cancelled { throw CancellationError() }
            return (p.terminationStatus, outData, errData)
        }.value
    } onCancel: {
        cp.cancel()
    }
}

@MainActor
final class RMClient: ObservableObject {
    @Published var isAuthenticated = false
    @Published var lastError: String?

    /// Where the downloaded rmapi binary lives. We no longer bundle rmapi inside the
    /// app — it's fetched once from ddvk/rmapi's GitHub releases on first use and cached
    /// here, so the app picks up new rmapi versions without us shipping an app update.
    private var binDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("tinyreMarkable/bin", isDirectory: true)
    }
    private var installedBinaryURL: URL { binDir.appendingPathComponent("rmapi") }

    /// The release asset to download for this Mac's architecture.
    private static var assetName: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        return machine == "x86_64" ? "rmapi-macos-intel.zip" : "rmapi-macos-arm64.zip"
    }

    /// Stable URL that always redirects to the newest release's asset.
    private static var downloadURL: URL {
        URL(string: "https://github.com/ddvk/rmapi/releases/latest/download/\(assetName)")!
    }

    /// In-flight install, so concurrent callers share one download instead of racing.
    private var installTask: Task<URL, Error>?

    /// Returns the rmapi binary, downloading and caching it on first use.
    func ensureBinary() async throws -> URL {
        if FileManager.default.isExecutableFile(atPath: installedBinaryURL.path) {
            return installedBinaryURL
        }
        if let installTask { return try await installTask.value }
        let task = Task { try await downloadAndInstallBinary() }
        installTask = task
        defer { installTask = nil }
        return try await task.value
    }

    /// Fetch the per-arch rmapi zip from GitHub, unzip it, and install the binary.
    private func downloadAndInstallBinary() async throws -> URL {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

            var request = URLRequest(url: Self.downloadURL)
            request.timeoutInterval = 120
            let (tmpFile, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw RMError.binaryDownloadFailed(detail: "HTTP \(http.statusCode) from \(Self.downloadURL.absoluteString)")
            }

            // download(for:) gives a temp file with no extension; unzip needs to see it as a zip.
            let zip = fm.temporaryDirectory.appendingPathComponent("rmapi-\(UUID().uuidString).zip")
            try? fm.removeItem(at: zip)
            try fm.moveItem(at: tmpFile, to: zip)
            defer { try? fm.removeItem(at: zip) }

            let extractDir = fm.temporaryDirectory.appendingPathComponent("rmapi-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: extractDir) }

            let (status, _, errData) = try await runProcessCancellable { p in
                p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                p.arguments = ["-o", "-q", zip.path, "-d", extractDir.path]
            }
            guard status == 0 else {
                throw RMError.binaryDownloadFailed(detail: "unzip failed: \(String(data: errData, encoding: .utf8) ?? "")")
            }

            // The archive contains a single file named `rmapi`.
            let extracted = extractDir.appendingPathComponent("rmapi")
            guard fm.fileExists(atPath: extracted.path) else {
                throw RMError.binaryDownloadFailed(detail: "Downloaded archive did not contain an rmapi binary.")
            }

            try? fm.removeItem(at: installedBinaryURL)
            try fm.moveItem(at: extracted, to: installedBinaryURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBinaryURL.path)
            return installedBinaryURL
        } catch let error as RMError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RMError.binaryDownloadFailed(detail: error.localizedDescription)
        }
    }

    private var rmapiConfigDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("rmapi", isDirectory: true)
    }

    private var rmapiConfigFile: URL {
        rmapiConfigDir.appendingPathComponent("rmapi.conf")
    }

    private var desktopPrefsPlist: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Containers/com.remarkable.desktop/Data/Library/Preferences/com.remarkable.desktop.plist"
        )
    }

    // MARK: - Auth

    func bootstrapAuthIfNeeded() throws {
        if FileManager.default.fileExists(atPath: rmapiConfigFile.path) {
            isAuthenticated = true
            return
        }
        if let token = try? readDeviceTokenFromDesktopApp() {
            try FileManager.default.createDirectory(at: rmapiConfigDir, withIntermediateDirectories: true)
            let conf = "devicetoken: \(token)\n"
            try conf.write(to: rmapiConfigFile, atomically: true, encoding: .utf8)
            isAuthenticated = true
        } else {
            isAuthenticated = false
        }
    }

    /// Page where the user obtains the 8-character one-time pairing code.
    static let connectURL = URL(string: "https://my.remarkable.com/device/browser/connect")!

    /// Pair this app with the reMarkable cloud using a one-time code (the fallback
    /// when the desktop app isn't installed). Runs rmapi with the code on stdin;
    /// rmapi registers a device and writes rmapi.conf. A watchdog guards against
    /// rmapi's habit of looping forever when the code is rejected.
    func register(oneTimeCode rawCode: String) async throws {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 8 else { throw RMError.pairingCodeInvalid }

        try FileManager.default.createDirectory(at: rmapiConfigDir, withIntermediateDirectories: true)
        // Start clean so a stale/partial config can't mask a failed pairing.
        try? FileManager.default.removeItem(at: rmapiConfigFile)

        let bin = try await ensureBinary()
        let detail: String = try await Task.detached {
            let p = Process()
            p.executableURL = bin
            p.arguments = ["ls"] // any auth-requiring command triggers registration first
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "RMAPI_CONFIG")
            p.environment = env

            let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe

            try p.run()
            try? inPipe.fileHandleForWriting.write(contentsOf: Data((code + "\n").utf8))
            try? inPipe.fileHandleForWriting.close()

            // Watchdog: rmapi re-prompts in a tight loop on a bad code (and hits EOF
            // immediately since stdin is closed), so never wait indefinitely.
            let deadline = Date().addingTimeInterval(45)
            while p.isRunning && Date() < deadline {
                usleep(150_000)
            }
            if p.isRunning {
                p.terminate()
                p.waitUntilExit()
            }

            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let err = String(data: errData, encoding: .utf8) ?? ""
            let out = String(data: outData, encoding: .utf8) ?? ""
            return err.isEmpty ? out : err
        }.value

        // Success is defined by rmapi having written a usable config (a device token),
        // independent of whether the subsequent `ls` succeeded (it can fail offline).
        if hasDeviceToken() {
            isAuthenticated = true
            return
        }
        isAuthenticated = false
        throw RMError.pairingFailed(detail: RMError.from(rmapiOutput: detail).errorDescription ?? detail)
    }

    /// Whether rmapi.conf exists and carries a non-empty device token.
    private func hasDeviceToken() -> Bool {
        guard let conf = try? String(contentsOf: rmapiConfigFile, encoding: .utf8) else { return false }
        for line in conf.split(separator: "\n") where line.hasPrefix("devicetoken:") {
            let value = line.dropFirst("devicetoken:".count).trimmingCharacters(in: .whitespaces)
            return !value.isEmpty
        }
        return false
    }

    private func readDeviceTokenFromDesktopApp() throws -> String {
        let data = try Data(contentsOf: desktopPrefsPlist)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else { throw RMError.notAuthenticated }
        if let tokenData = dict["devicetoken"] as? Data,
           let str = String(data: tokenData, encoding: .utf8) {
            return str
        }
        throw RMError.notAuthenticated
    }

    // MARK: - rmapi invocation

    @discardableResult
    private func run(_ args: [String], input: String? = nil) async throws -> String {
        let bin = try await ensureBinary()
        // Force rmapi to use the standard config path even when bundle paths shift.
        var mutableEnv = ProcessInfo.processInfo.environment
        mutableEnv.removeValue(forKey: "RMAPI_CONFIG")
        let env = mutableEnv
        let (status, outData, errData) = try await runProcessCancellable(input: input) { p in
            p.executableURL = bin
            p.arguments = args
            p.environment = env
        }
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        if status != 0 {
            throw RMError.from(rmapiOutput: errStr.isEmpty ? outStr : errStr)
        }
        return outStr
    }

    // MARK: - Commands

    /// List entries at remote path. `path` like "/" or "/Books".
    func list(path: String = "/") async throws -> [RMItem] {
        let out = try await run(["ls", path])
        var items: [RMItem] = []
        for rawLine in out.split(separator: "\n") {
            let line = String(rawLine)
            // Lines look like "[d]\tName" or "[f]\tName"
            guard line.hasPrefix("[d]") || line.hasPrefix("[f]") else { continue }
            let kind: RMItem.Kind = line.hasPrefix("[d]") ? .folder : .document
            let name = line
                .replacingOccurrences(of: "[d]\t", with: "")
                .replacingOccurrences(of: "[f]\t", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let normalizedPath = path.hasSuffix("/") ? path : path + "/"
            let fullPath = normalizedPath + name
            items.append(RMItem(id: fullPath, name: name, kind: kind))
        }
        return items.sorted {
            if $0.kind != $1.kind { return $0.kind == .folder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Upload a local file to the cloud at the given remote folder (e.g. "/").
    func upload(localFile: URL, remoteFolder: String) async throws {
        _ = try await run(["put", localFile.path, remoteFolder])
    }

    /// Download the raw .zip archive for a cloud document via `rmapi get`.
    /// Returns the URL of the downloaded zip inside `destinationDir`.
    func downloadArchive(remotePath: String, destinationDir: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let bin = try await ensureBinary()
        let (status, _, errData) = try await runProcessCancellable { p in
            p.executableURL = bin
            p.arguments = ["get", remotePath]
            p.currentDirectoryURL = destinationDir
        }

        if status != 0 {
            let err = RMError.from(rmapiOutput: String(data: errData, encoding: .utf8) ?? "")
            if case .notFound = err { throw RMError.notFound(path: remotePath) }
            throw err
        }

        // rmapi names the file <basename>.zip for PDFs and <basename>.rmdoc for notebooks.
        // Both are ordinary zip archives.
        let candidates = try FileManager.default.contentsOfDirectory(at: destinationDir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter {
                let ext = $0.pathExtension.lowercased()
                return ext == "zip" || ext == "rmdoc"
            }
        guard let zip = candidates.first else {
            throw RMError.rmapiFailed(stderr: "No archive produced by rmapi get")
        }
        return zip
    }

    /// Download and unzip a document, returning a handle plus its page count — without
    /// rendering anything. Cheap even for large notebooks.
    func prepare(remotePath: String, destinationDir: URL, progress: @MainActor @escaping (String) -> Void) async throws -> PreparedDocument {
        progress("Downloading…")
        let zip = try await downloadArchive(remotePath: remotePath, destinationDir: destinationDir)
        let unzipped = destinationDir.appendingPathComponent("unzipped", isDirectory: true)
        try? FileManager.default.removeItem(at: unzipped)
        try FileManager.default.createDirectory(at: unzipped, withIntermediateDirectories: true)
        try await unzip(archive: zip, into: unzipped)

        let archive = try RMArchive(directory: unzipped)
        if let embedded = archive.embeddedPDF {
            let count = PDFDocument(url: embedded)?.pageCount ?? archive.pageUUIDs.count
            // If the user wrote on the PDF, the ink lives in per-page `.rm` files
            // alongside the source PDF; it must be rendered and composited on export.
            // A plain uploaded PDF with no strokes skips that and exports as-is.
            let source: PreparedDocument.Source = archive.hasAnnotations
                ? .annotatedPDF(pdf: embedded, archive: archive)
                : .embeddedPDF(embedded)
            return PreparedDocument(source: source, pageCount: count, name: archive.visibleName)
        }
        return PreparedDocument(source: .notebook(archive), pageCount: archive.pageUUIDs.count, name: archive.visibleName)
    }

    /// Produce a PDF for the given pages (nil = all pages) from a prepared document.
    /// For notebooks this renders only the requested pages. For embedded PDFs the full
    /// PDF already exists, so the whole file is returned and the caller slices if needed.
    func makePDF(from doc: PreparedDocument, pageIndices: [Int]?, destinationDir: URL, progress: @MainActor @escaping (String) -> Void) async throws -> URL {
        switch doc.source {
        case .embeddedPDF(let url):
            return url
        case .annotatedPDF(let pdf, let archive):
            // Render the handwritten strokes for the requested pages and composite
            // them onto the source PDF. Produces exactly the requested pages, so the
            // caller copies the result directly (no further slicing).
            let suffix = pageIndices == nil ? "annotated" : "annotated-\(pageIndices!.map(String.init).joined(separator: "-"))"
            let outURL = destinationDir.appendingPathComponent("\(doc.name).\(suffix).pdf")
            try await NotebookRenderer.shared.compositeAnnotatedPDF(archive: archive, sourcePDF: pdf, to: outURL, pageIndices: pageIndices, progress: progress)
            return outURL
        case .notebook(let archive):
            let suffix = pageIndices == nil ? "rendered" : "rendered-\(pageIndices!.map(String.init).joined(separator: "-"))"
            let outURL = destinationDir.appendingPathComponent("\(doc.name).\(suffix).pdf")
            try await NotebookRenderer.shared.render(archive: archive, to: outURL, pageIndices: pageIndices, progress: progress)
            return outURL
        }
    }

    private func unzip(archive: URL, into dir: URL) async throws {
        let (status, _, errData) = try await runProcessCancellable { p in
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-o", "-q", archive.path, "-d", dir.path]
        }
        if status != 0 {
            throw RMError.rmapiFailed(stderr: "Could not unzip archive: \(String(data: errData, encoding: .utf8) ?? "")")
        }
    }
}
