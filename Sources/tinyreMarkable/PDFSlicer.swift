import Foundation
import PDFKit

enum PDFSlicer {
    static func extractPages(from source: URL, indices: [Int], to destination: URL) throws {
        guard let src = PDFDocument(url: source) else {
            throw NSError(domain: "PDFSlicer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open source PDF"])
        }
        let out = PDFDocument()
        var insertIndex = 0
        for i in indices {
            guard let page = src.page(at: i)?.copy() as? PDFPage else { continue }
            out.insert(page, at: insertIndex)
            insertIndex += 1
        }
        guard out.pageCount > 0 else {
            throw NSError(domain: "PDFSlicer", code: 2, userInfo: [NSLocalizedDescriptionKey: "No pages selected"])
        }
        guard out.write(to: destination) else {
            throw NSError(domain: "PDFSlicer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not write PDF"])
        }
    }
}
