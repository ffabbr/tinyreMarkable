import Foundation

struct RMItem: Identifiable, Hashable {
    enum Kind { case folder, document }
    let id: String           // full remote path, e.g. "/Books/Foo"
    let name: String
    let kind: Kind
    var parentPath: String {
        let trimmed = id.hasSuffix("/") ? String(id.dropLast()) : id
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let p = String(trimmed[..<slash])
        return p.isEmpty ? "/" : p
    }
}
