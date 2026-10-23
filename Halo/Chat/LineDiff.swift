import Foundation

/// Line-based diff for artifact version comparison.
enum LineDiff {
    enum Kind: Equatable { case same, added, removed }

    struct Row: Equatable, Identifiable {
        var id: Int
        var kind: Kind
        var text: String
    }

    static func diff(old: String, new: String) -> [Row] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let difference = b.difference(from: a)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                rows.append(Row(id: rows.count, kind: .removed, text: a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                rows.append(Row(id: rows.count, kind: .added, text: b[j])); j += 1
            } else if i < a.count, j < b.count {
                rows.append(Row(id: rows.count, kind: .same, text: b[j])); i += 1; j += 1
            } else if i < a.count {
                rows.append(Row(id: rows.count, kind: .removed, text: a[i])); i += 1
            } else {
                rows.append(Row(id: rows.count, kind: .added, text: b[j])); j += 1
            }
        }
        return rows
    }

    static func stats(_ rows: [Row]) -> (added: Int, removed: Int) {
        (rows.filter { $0.kind == .added }.count, rows.filter { $0.kind == .removed }.count)
    }
}
