import Foundation
import Combine
import PDFKit

/// A downloaded, unzipped document ready to be turned into PDF pages — but not yet
/// rendered. Lets callers learn the page count cheaply and render only the pages they
/// need (handwritten notebooks are expensive to render per page).
struct PreparedDocument {
    enum Source {
        /// Uploaded/annotated PDF: a complete PDF already exists on disk.
        case embeddedPDF(URL)
        /// Pure handwritten notebook: pages must be rendered on demand.
        case notebook(RMArchive)
    }
    let source: Source
    let pageCount: Int
    let name: String
}

enum RMError: LocalizedError {
    case binaryMissing
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
        case .binaryMissing:
            return "Bundled rmapi binary not found."
        case .offline:
            return "No internet connection. Connect to the internet and try again."
        case .authExpired:
            return "Your reMarkable session has expired. Open the reMarkable desktop app to sign in again, then retry."
        case .notebookNotRenderable(let name):
            return "“\(name)” is a handwritten notebook with no source PDF. Exporting handwritten notebooks to PDF isn’t supported yet — annotated PDFs work fine. Workaround: open the notebook in the reMarkable desktop app and use File → Export."
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
        if lower.contains("no such host")
            || lower.contains("dial tcp")
            || lower.contains("network is unreachable")
            || lower.contains("no route to host")
            || lower.contains("connection refused")
            || lower.contains("i/o timeout") {
            return .offline
        }
        if lower.contains("failed to create user token")
            || lower.contains("unauthorized")
            || lower.contains("401")
            || lower.contains("token is expired")
            || lower.contains("invalid token") {
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

    private var binaryURL: URL {
        // Bundle.module is generated by SwiftPM for resources in this target.
        Bundle.module.url(forResource: "rmapi", withExtension: nil)!
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

        let bin = binaryURL
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
        let bin = binaryURL
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
        let bin = binaryURL
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
            return PreparedDocument(source: .embeddedPDF(embedded), pageCount: count, name: archive.visibleName)
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
