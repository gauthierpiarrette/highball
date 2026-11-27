import Foundation

/// Highball's signed Wine loader for arm64 engines.
///
/// A Wine that runs x86 programs natively on Apple silicon needs Apple's cross-architecture
/// entitlement on the loader process: it is what lets the process keep the x18 register for the
/// Windows thread block, map the low 4 GB, and set total store ordering per thread (macOS 26.5
/// and later, private/notes/rosetta-transition-plan.md). The entitlement is granted to a signed app
/// bundle carrying a provisioning profile, so the loader cannot be a file inside a downloaded
/// engine. It ships inside Highball.app as Contents/Helpers/WineLoader.app (bundle id
/// app.highball.WineLoader, built by Scripts/make-app.sh from spike/wineloader), and every arm64
/// engine's `wine` becomes a symlink to it (EngineStore.linkSignedLoader). Wine's ntdll starts child
/// processes through `<directory of ntdll.so>/wine`, and the helper looks for ntdll.so beside the
/// path it was started by, so one sealed bundle serves every engine and nothing is copied into it.
/// Measured on an M4, macOS 27.0, 2026-10-04.
public enum WineLoaderHelper {
    public static let bundleName = "WineLoader.app"
    public static let bundleIdentifier = "app.highball.WineLoader"
    /// Path to the helper bundle, or to its `wine` binary, for the CLI and the test harness, which
    /// run outside Highball.app.
    public static let environmentKey = "HIGHBALL_WINELOADER"

    /// Where a bundle keeps the helper.
    public static func binary(inAppBundle app: URL) -> URL {
        app.appending(path: "Contents/Helpers/\(bundleName)/Contents/MacOS/wine")
    }

    /// The helper's `wine` binary: named in the environment, then inside this app's own bundle,
    /// then inside an installed Highball.app, wherever it is (InstalledHighball). nil when no copy
    /// is on this Mac, which is the CLI on a Mac without the app.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              appBundle: URL? = Bundle.main.bundleURL,
                              applications: [URL]? = nil) -> URL? {
        var candidates: [URL] = []
        if let p = environment[environmentKey], !p.isEmpty {
            let url = URL(fileURLWithPath: p)
            candidates.append(url.pathExtension == "app" ? url.appending(path: "Contents/MacOS/wine") : url)
        }
        if let appBundle, appBundle.pathExtension == "app" { candidates.append(binary(inAppBundle: appBundle)) }
        if let first = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return first }
        return (applications ?? InstalledHighball.apps()).map(binary(inAppBundle:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Whether a symlink destination is the helper's binary.
    public static func isHelperPath(_ path: String) -> Bool {
        path.hasSuffix("/\(bundleName)/Contents/MacOS/wine")
    }
}
