import Foundation

/// Parsed contents of an unzipped reMarkable archive.
struct RMArchive {
    let directory: URL
    let docUUID: String
    let visibleName: String
    /// Ordered page UUIDs (from .content cPages.pages[]).
    let pageUUIDs: [String]
    /// Source PDF embedded in the archive (the document was uploaded as PDF), if any.
    let embeddedPDF: URL?

    init(directory: URL) throws {
        self.directory = directory
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        guard let contentFile = files.first(where: { $0.pathExtension == "content" }) else {
            throw NSError(domain: "RMArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Archive missing .content file"])
        }
        self.docUUID = contentFile.deletingPathExtension().lastPathComponent

        let contentData = try Data(contentsOf: contentFile)
        let json = (try JSONSerialization.jsonObject(with: contentData)) as? [String: Any] ?? [:]

        var pages: [String] = []
        if let cPages = json["cPages"] as? [String: Any],
           let list = cPages["pages"] as? [[String: Any]] {
            for p in list {
                // Skip deleted pages: they have a "deleted" timestamp marker.
                if p["deleted"] != nil { continue }
                if let id = p["id"] as? String { pages.append(id) }
            }
        } else if let oldPages = json["pages"] as? [String] {
            // older layout
            pages = oldPages
        }
        self.pageUUIDs = pages

        // Metadata file → visibleName
        var name = self.docUUID
        if let meta = files.first(where: { $0.pathExtension == "metadata" }),
           let data = try? Data(contentsOf: meta),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let v = obj["visibleName"] as? String {
            name = v
        }
        self.visibleName = name

        // Embedded source PDF: a .pdf file with the same UUID name as docUUID.
        let embedded = directory.appendingPathComponent("\(docUUID).pdf")
        self.embeddedPDF = FileManager.default.fileExists(atPath: embedded.path) ? embedded : nil
    }

    /// True when at least one page carries handwritten `.rm` strokes — i.e. the
    /// document is an annotated PDF (embedded source PDF + ink) rather than a
    /// plain uploaded PDF. Used to decide whether annotations must be composited.
    var hasAnnotations: Bool {
        pageUUIDs.contains { rmFile(for: $0) != nil }
    }

    /// Path to a page's .rm file (may not exist if the page has no annotations / strokes).
    func rmFile(for pageUUID: String) -> URL? {
        let url = directory
            .appendingPathComponent(docUUID, isDirectory: true)
            .appendingPathComponent("\(pageUUID).rm")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
