import Foundation
import PDFKit

enum PDFSlicer {
    /// Parse a 1-based page range string like "1-3,5,7-9" against a known page count.
    /// Returns 0-based indices, deduplicated and sorted.
    static func parseRanges(_ input: String, pageCount: Int) -> [Int] {
        var set = Set<Int>()
        for chunk in input.split(separator: ",") {
            let part = chunk.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            if let dash = part.firstIndex(of: "-") {
                let lo = Int(part[..<dash].trimmingCharacters(in: .whitespaces)) ?? 0
                let hi = Int(part[part.index(after: dash)...].trimmingCharacters(in: .whitespaces)) ?? 0
                let a = max(1, min(lo, hi))
                let b = min(pageCount, max(lo, hi))
                if a <= b { for p in a...b { set.insert(p - 1) } }
            } else if let p = Int(part), p >= 1, p <= pageCount {
                set.insert(p - 1)
            }
        }
        return set.sorted()
    }

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

    static func pageCount(of url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }
}
