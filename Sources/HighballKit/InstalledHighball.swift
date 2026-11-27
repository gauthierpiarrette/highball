import Foundation
import CoreServices

/// The Highball.app copies on this Mac, for code that runs outside the app, such as a CLI built
/// from source that borrows the app's cabextract or its signed Wine loader. The usual places come
/// first, then every other copy Launch Services knows by bundle id, wherever it was put: an app in
/// /Applications/#emu was never found when only /Applications and ~/Applications were looked in
/// (highball-db#941).
public enum InstalledHighball {
    public static let bundleID = "app.highball.Highball"

    public static func apps() -> [URL] {
        var urls = [URL(fileURLWithPath: "/Applications/Highball.app"),
                    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Highball.app")]
        if let found = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] {
            urls += found
        }
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL).filter {
            FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted
        }
    }
}
