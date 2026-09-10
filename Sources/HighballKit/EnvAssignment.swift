import Foundation

/// One `KEY=VALUE` assignment from the CLI. An empty value removes the key, so a user can
/// undo `env FOO=bar` with `env FOO=`. Swift's `split` drops the empty trailing piece, which
/// is why `KEY=` used to be rejected as "not KEY=VALUE".
public enum EnvAssignment {
    public static func parse(_ text: String) -> (key: String, value: String)? {
        guard let eq = text.firstIndex(of: "=") else { return nil }
        let key = String(text[..<eq])
        guard !key.isEmpty else { return nil }
        return (key, String(text[text.index(after: eq)...]))
    }

    /// Applies the assignment to `environment`; returns false when the text is not `KEY=VALUE`.
    @discardableResult
    public static func apply(_ text: String, to environment: inout [String: String]) -> Bool {
        guard let (key, value) = parse(text) else { return false }
        if value.isEmpty { environment.removeValue(forKey: key) } else { environment[key] = value }
        return true
    }
}
