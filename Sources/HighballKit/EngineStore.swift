import CryptoKit
import Foundation

public enum HighballError: Error, CustomStringConvertible {
    case checksumMismatch(file: String, expected: String, actual: String)
    case processFailed(command: String, status: Int32, output: String)
    case missing(String)
    case invalid(String)
    /// A message already written for the user. Carries no prefix, so it reads as a sentence
    /// rather than as a category the reader has to decode.
    case failed(String)

    public var description: String {
        switch self {
        case let .checksumMismatch(file, expected, actual):
            return "checksum mismatch for \(file): expected \(expected), got \(actual)"
        case let .processFailed(command, status, output):
            return "\(command) exited with \(status)\n\(output)"
        case let .missing(what): return "missing: \(what)"
        case let .invalid(what): return "invalid: \(what)"
        case let .failed(message): return message
        }
    }
}

/// Progress callback: (component name, bytes received, total bytes or nil).
public typealias DownloadProgress = @Sendable (String, Int64, Int64?) -> Void

/// Downloads, verifies and lays out engines from manifests.
///
/// Installed layout: `engines/<id>/{engine, frameworks, renderers/<name>/..., manifest.json}`
public struct EngineStore: Sendable {
    public let paths: HighballPaths

    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    // MARK: Query

    public func installedEngines() throws -> [InstalledEngine] {
        guard FileManager.default.fileExists(atPath: paths.engines.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(at: paths.engines, includingPropertiesForKeys: nil)
        return dirs.compactMap { dir in
            let manifest = dir.appending(path: "manifest.json")
            guard let m = try? EngineManifest.load(from: manifest) else { return nil }
            try? linkRuntime(dir)   // heals broken runtime links from pre-0.7.9 installs
            return InstalledEngine(manifest: m, root: dir)
        }.sorted { $0.manifest.id < $1.manifest.id }
    }

    /// The engine to use by default: the one the bundled manifest names when it is installed,
    /// else the newest installed. Newest is the highest id under numeric-aware ordering, so
    /// `…-r10` beats `…-r9` and `…-r2`. After an engine update two engines coexist, and the
    /// CLI, which has no bundled manifest, created bottles on the old one while the app used
    /// the new one (found 2026-09-04: a bottle created from the CLI ran r0 next to the app's r1).
    public static func defaultEngine(installed: [InstalledEngine], bundledID: String?) -> InstalledEngine? {
        installed.first { $0.id == bundledID }
            ?? installed.max { $0.id.compare($1.id, options: .numeric) == .orderedAscending }
    }

    /// Engines nothing references any more: not the default and not the engine of any bottle.
    /// An engine update never removes an engine a bottle still runs on; a bottle keeps its
    /// engine until its owner switches it (per-bottle choice, not migration).
    public static func unreferencedEngines(installed: [InstalledEngine], referencedIDs: Set<String>, defaultID: String?) -> [InstalledEngine] {
        installed.filter { $0.id != defaultID && !referencedIDs.contains($0.id) }
    }

    /// The engine to offer when a program fails on `currentID`: the default engine when the
    /// bottle is not on it (the newer one, usually), else the newest other installed engine.
    /// nil with a single engine installed.
    public static func alternateEngine(for currentID: String, installed: [InstalledEngine], defaultID: String?) -> InstalledEngine? {
        if let d = installed.first(where: { $0.id == defaultID }), d.id != currentID { return d }
        return installed.filter { $0.id != currentID }
            .max { $0.id.compare($1.id, options: .numeric) == .orderedAscending }
    }

    public func engine(_ id: String) throws -> InstalledEngine {
        let root = paths.engine(id)
        let m = try EngineManifest.load(from: root.appending(path: "manifest.json"))
        try? linkRuntime(root)      // heals broken runtime links from pre-0.7.9 installs
        return InstalledEngine(manifest: m, root: root)
    }

    // MARK: Install

    /// Installs every component of `manifest`. Optional components are skipped unless their
    /// `acceptance` id is in `accepted` (or they have no acceptance requirement and `includeOptional`).
    public func install(
        _ manifest: EngineManifest,
        accepted: Set<String> = [],
        includeOptional: Bool = true,
        progress: DownloadProgress? = nil
    ) async throws -> InstalledEngine {
        try paths.ensure()
        let root = paths.engine(manifest.id)
        let staging = paths.engines.appending(path: ".\(manifest.id).partial", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        for (name, component) in manifest.orderedComponents {
            if component.isOptional {
                if let acceptance = component.acceptance, !accepted.contains(acceptance) { continue }
                if component.acceptance == nil, !includeOptional { continue }
            }
            let archive = try await download(component, name: name, progress: progress)
            try extract(archive, component: component, name: name, into: staging)
        }

        var saved = manifest
        saved.acceptedLicenses = Array(accepted).sorted()
        try saved.save(to: staging.appending(path: "manifest.json"))
        try linkRuntime(staging)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: staging, to: root)
        try stripQuarantine(root)
        return InstalledEngine(manifest: saved, root: root)
    }

    /// Records acceptance of a license for an already-installed engine.
    public func accept(license id: String, engine: InstalledEngine) throws -> InstalledEngine {
        var m = engine.manifest
        var set = Set(m.acceptedLicenses ?? []); set.insert(id)
        m.acceptedLicenses = set.sorted()
        try m.save(to: engine.root.appending(path: "manifest.json"))
        return InstalledEngine(manifest: m, root: engine.root)
    }

    /// Downloads to `downloads/<basename>` and verifies SHA-256. Reuses a cached file if it verifies.
    public func download(_ component: EngineManifest.Component, name: String, progress: DownloadProgress? = nil) async throws -> URL {
        try paths.ensure()
        let dest = paths.downloads.appending(path: component.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path), try sha256(of: dest) == component.sha256.lowercased() {
            return dest
        }
        // Delegate-based download: real progress every ~2 MB (the app was showing a blank sheet
        // for the whole 270 MB), and a 60 s no-data timeout so a stalled connection fails loudly
        // instead of hanging forever (URLSession.shared's resource timeout is 7 days).
        let expected = Int64(component.size ?? 0)
        let delegate = ProgressingDownload(dest: dest) { received, total in
            progress?(name, received, total > 0 ? total : expected)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.continuation = cont
            session.downloadTask(with: component.url).resume()
        }
        let actual = try sha256(of: dest)
        guard actual == component.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: dest)
            throw HighballError.checksumMismatch(file: dest.lastPathComponent, expected: component.sha256, actual: actual)
        }
        progress?(name, expected > 0 ? expected : 1, expected > 0 ? expected : 1)
        return dest
    }

    func extract(_ archive: URL, component: EngineManifest.Component, name: String, into root: URL) throws {
        guard let ex = component.extract else {
            // Plain file (e.g. winetricks script): copy into tools/.
            let tools = root.appending(path: "tools", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            let dest = tools.appending(path: archive.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: archive, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            return
        }
        let scratch = root.appending(path: ".extract-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", scratch.path])

        let source: URL
        if let sub = ex.subpath ?? ex.strip {
            source = scratch.appending(path: sub)
        } else {
            source = scratch
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw HighballError.missing("\(ex.subpath ?? ex.strip ?? "") inside \(archive.lastPathComponent)")
        }
        // `into` names a directory (a whole overlay) or a single file: a component that replaces
        // one file another component installed, like a patched libMoltenVK.dylib on top of the
        // runtime's. A file target leaves the rest of the parent directory alone.
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
        let dest = root.appending(path: ex.into, directoryHint: isDir.boolValue ? .isDirectory : .notDirectory)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: source, to: dest)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Symlinks the Template's runtime dylibs into engine/lib so Wine binaries resolve
    /// @loader_path/../lib/… and @rpath names without any DYLD_* environment (which SIP
    /// strips when a restricted binary like /bin/sh sits in the exec chain — winetricks does).
    ///
    /// Targets MUST be relative: install() links inside the .partial staging dir and then
    /// renames it into place, so absolute targets died with the staging path — every fresh
    /// install shipped broken links until 0.7.9 (caught by the dotnet48 E2E gate; games
    /// still ran because launches carry DYLD_FALLBACK_LIBRARY_PATH, winetricks did not).
    /// A link with any other target is replaced, which also heals engines installed by
    /// older versions when this runs again from installedEngines()/engine(_:).
    func linkRuntime(_ root: URL) throws {
        let fm = FileManager.default
        let engineLib = root.appending(path: "engine/lib", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: engineLib.path) else { return }
        var handled = Set<String>()
        func link(_ name: String, to relativeTarget: String) {
            guard handled.insert(name).inserted else { return }   // first source dir wins, as before
            let dest = engineLib.appending(path: name)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: dest.path) {
                if existing == relativeTarget { return }
                try? fm.removeItem(at: dest)      // absolute/staging target from a pre-0.7.9 install
            } else if fm.fileExists(atPath: dest.path) {
                return                            // a real file — leave it alone
            }
            try? fm.createSymbolicLink(atPath: dest.path, withDestinationPath: relativeTarget)
        }
        for sub in ["frameworks", "frameworks/GStreamer.framework/Versions/1.0/lib"] {
            let dir = root.appending(path: sub, directoryHint: .isDirectory)
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension == "dylib" {
                link(entry.lastPathComponent, to: "../../\(sub)/\(entry.lastPathComponent)")
            }
        }
        // GStreamer.framework itself, for modules that reference it by framework path.
        link("GStreamer.framework", to: "../../frameworks/GStreamer.framework")
    }

    func stripQuarantine(_ url: URL) throws {
        try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
    }

    public func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// An engine that has been laid out on disk.
public struct InstalledEngine: Sendable {
    public let manifest: EngineManifest
    public let root: URL

    public var id: String { manifest.id }
    /// Short human name for UI ("Wine 10.0 (Sikarugir)" beats a manifest id).
    public var displayName: String {
        manifest.components["wine"]?.version ?? manifest.displayName
    }
    public var engineDir: URL { root.appending(path: "engine", directoryHint: .isDirectory) }
    public var frameworksDir: URL { root.appending(path: "frameworks", directoryHint: .isDirectory) }
    public var renderersDir: URL { root.appending(path: "renderers", directoryHint: .isDirectory) }
    public var wineBinary: URL { engineDir.appending(path: "bin/wine") }
    public var wineserverBinary: URL { engineDir.appending(path: "bin/wineserver") }
    public var winetricks: URL? {
        let t = root.appending(path: "tools/winetricks")
        return FileManager.default.fileExists(atPath: t.path) ? t : nil
    }

    /// Renderer overlay directory: Gin's own `renderers/<name>` wins over the Template's `frameworks/renderer/<name>`.
    public func rendererDir(_ name: String) -> URL? {
        if let gate = EngineManifest.gatedRenderers[name], !(manifest.acceptedLicenses ?? []).contains(gate) { return nil }
        let own = renderersDir.appending(path: name, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: own.appending(path: "wine").path) { return own }
        let template = frameworksDir.appending(path: "renderer/\(name)", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: template.appending(path: "wine").path) { return template }
        return nil
    }

    public func wineVersion() throws -> String {
        try Shell.capture(wineBinary.path, ["--version"], env: baseEnvironment()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Environment every Wine process needs for this engine, before bottle/renderer settings.
    public func baseEnvironment() -> [String: String] {
        let fw = frameworksDir.path
        var env: [String: String] = [
            "DYLD_FALLBACK_LIBRARY_PATH": "\(fw):\(fw)/GStreamer.framework/Versions/1.0/lib",
            "DYLD_FALLBACK_FRAMEWORK_PATH": fw,
            "GST_PLUGIN_PATH": "\(fw)/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0",
        ]
        for (k, v) in manifest.baseEnv ?? [:] {
            env[k] = v.replacingOccurrences(of: "${frameworks}", with: fw)
                       .replacingOccurrences(of: "${renderers}", with: renderersDir.path)
        }
        return env
    }
}

/// URLSessionDownloadDelegate that streams byte progress (~every 2 MB) and moves the finished
/// file into place before resuming its continuation. State is confined to the session's own
/// serial delegate queue, hence @unchecked Sendable.
final class ProgressingDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var lastReported: Int64 = 0
    private var moveError: Error?
    var continuation: CheckedContinuation<Void, Error>?

    init(dest: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.dest = dest
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten - lastReported >= 2_000_000 || totalBytesWritten == totalBytesExpectedToWrite {
            lastReported = totalBytesWritten
            onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = HighballError.invalid("HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.absoluteString ?? "download")")
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cont = continuation
        continuation = nil
        if let error { cont?.resume(throwing: error) }
        else if let moveError { cont?.resume(throwing: moveError) }
        else { cont?.resume() }
    }
}
