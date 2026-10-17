import Foundation

public enum DiffLine: Equatable, Sendable {
    case same(String), added(String), removed(String)
}

/// Diff por líneas (LCS), para mostrar qué cambia una propuesta de skill.
public enum LineDiff {
    public static func diff(old: String, new: String) -> [DiffLine] {
        let a = lines(old), b = lines(new)
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { out.append(.same(a[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { out.append(.removed(a[i])); i += 1 }
            else { out.append(.added(b[j])); j += 1 }
        }
        while i < a.count { out.append(.removed(a[i])); i += 1 }
        while j < b.count { out.append(.added(b[j])); j += 1 }
        return out
    }

    private static func lines(_ s: String) -> [String] {
        s.isEmpty ? [] : s.components(separatedBy: "\n")
    }
}
