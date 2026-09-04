import Foundation

/// Reads values out of Wine's text registry files (system.reg, user.reg) without running Wine.
/// Keys appear as `[Software\\Vendor\\Key] <timestamp>` with backslashes doubled, values below
/// them as `"Name"=dword:00000001` or `"Name"="text"`. Pure, so the Dependencies detection can
/// be tested with a string.
public enum RegistryText {
    /// The raw value text (`dword:00000001`, `"text"`, `hex:...`) for `name` under `key`, or nil.
    /// `key` is written the way it appears in the file, with doubled backslashes, or with single
    /// backslashes, which are doubled here.
    public static func value(in text: String, key: String, name: String) -> String? {
        let wanted = "[" + key.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\", with: "\\\\") + "]"
        var inKey = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") {
                inKey = line.hasPrefix(wanted + " ") || line == Substring(wanted)
                continue
            }
            guard inKey, line.hasPrefix("\"" + name + "\"=") else { continue }
            return String(line.dropFirst(name.count + 3))
        }
        return nil
    }

    /// `dword:00082348` -> 533320.
    public static func dword(_ raw: String) -> Int? {
        guard raw.lowercased().hasPrefix("dword:") else { return nil }
        return Int(raw.dropFirst(6), radix: 16)
    }
}
