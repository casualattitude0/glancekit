import Foundation

/// A tiny, defensive evaluator for a dot/bracket path into a Foundation JSON
/// tree (as produced by `JSONSerialization`). Supports dictionary keys
/// (`data.price`) and array subscripts (`results[0].value`). Never throws —
/// returns `nil` on any mismatch so callers can surface a friendly error.
enum JSONPath {
    /// Parse a path string like "results[0].value" into an ordered list of
    /// tokens: `.key("results")`, `.index(0)`, `.key("value")`.
    enum Token {
        case key(String)
        case index(Int)
    }

    static func tokenize(_ path: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""

        func flushKey() {
            if !current.isEmpty {
                tokens.append(.key(current))
                current = ""
            }
        }

        var iterator = path.makeIterator()
        while let ch = iterator.next() {
            switch ch {
            case ".":
                flushKey()
            case "[":
                flushKey()
                var indexString = ""
                while let inner = iterator.next(), inner != "]" {
                    indexString.append(inner)
                }
                if let idx = Int(indexString.trimmingCharacters(in: .whitespaces)) {
                    tokens.append(.index(idx))
                }
            default:
                current.append(ch)
            }
        }
        flushKey()
        return tokens
    }

    /// Walk `root` following `path`, returning the leaf value as a
    /// human-readable string, or `nil` if the path doesn't resolve.
    static func evaluate(path: String, in root: Any) -> String? {
        let tokens = tokenize(path)
        guard !tokens.isEmpty else { return stringify(root) }

        var current: Any = root
        for token in tokens {
            switch token {
            case .key(let key):
                guard let dict = current as? [String: Any], let next = dict[key] else {
                    return nil
                }
                current = next
            case .index(let idx):
                guard let array = current as? [Any], idx >= 0, idx < array.count else {
                    return nil
                }
                current = array[idx]
            }
        }
        return stringify(current)
    }

    /// Render a leaf JSON value as a display string.
    private static func stringify(_ value: Any) -> String? {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        case is NSNull:
            return "null"
        case let d as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: d),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{…}"
        case let a as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: a),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "[…]"
        default:
            return "\(value)"
        }
    }
}
