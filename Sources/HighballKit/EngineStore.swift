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

    /// Engines nothing references any more: not the default, not the engine of any bottle, and
    /// not one the app still offers (`keep`: the bundled manifests, so an engine someone
    /// downloaded for rollback survives the next update even with no bottle on it right now).
    /// An engine update never removes an engine a bottle still runs on; a bottle keeps its
    /// engine until its owner switches it (per-bottle choice, not migration).
    public static func unreferencedEngines(installed: [InstalledEngine], referencedIDs: Set<String>, defaultID: String?, keep: Set<String> = []) -> [InstalledEngine] {
        installed.filter { $0.id != defaultID && !referencedIDs.contains($0.id) && !keep.contains($0.id) }
    }

    /// The engine to offer when a program fails on `currentID`: the default engine when the
    /// bottle is not on it (the newer one, usually), else the newest other installed engine.
    /// nil with a single engine installed.
    public static func alternateEngine(for currentID: String, installed: [InstalledEngine], defaultID: String?) -> InstalledEngine? {
        if let d = installed.first(where: { $0.id == defaultID }), d.id != currentID { return d }
        return installed.filter { $0.id != currentID }
            .max { $0.id.compare($1.id, options: .numeric) == .orderedAscending }
    }

    /// One row per engine the app can put a bottle on: every installed engine, then every
    /// bundled manifest that is not installed yet (it downloads when chosen). Newest first
    /// within each group, by numeric-aware id order. When the bottle's own engine is in
    /// neither list (its directory is gone), it is appended as a `missing` row so the picker
    /// still shows what the bottle is on instead of a blank selection.
    public struct OfferedEngine: Equatable, Sendable {
        public let id: String
        public let installed: Bool
        public let missing: Bool
        public init(id: String, installed: Bool, missing: Bool = false) { self.id = id; self.installed = installed; self.missing = missing }
    }
    public static func offeredEngines(installed: [InstalledEngine], known: [EngineManifest], current: String? = nil) -> [OfferedEngine] {
        let newestFirst: (String, String) -> Bool = { $0.compare($1, options: .numeric) == .orderedDescending }
        let have = installed.sorted { newestFirst($0.id, $1.id) }.map { OfferedEngine(id: $0.id, installed: true) }
        let ids = Set(have.map(\.id))
        let more = known.filter { !ids.contains($0.id) }.sorted { newestFirst($0.id, $1.id) }
            .map { OfferedEngine(id: $0.id, installed: false) }
        var rows = have + more
        if let current, !rows.contains(where: { $0.id == current }) { rows.append(OfferedEngine(id: current, installed: false, missing: true)) }
        return rows
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
    ///
    /// Resumable and retried: the bytes land in `<basename>.partial` as they arrive, a retry asks
    /// for the rest with `Range` and `If-Range` on the ETag the first response carried, and up to
    /// three attempts with a short backoff run before the user sees anything. The checksum at the
    /// end stays the integrity backstop, so a bad resume can never install; a checksum failure
    /// discards the partial so the next attempt starts clean. A 60 s no-data timeout keeps a
    /// stalled connection from hanging forever.
    public func download(_ component: EngineManifest.Component, name: String, progress: DownloadProgress? = nil) async throws -> URL {
        try paths.ensure()
        let dest = paths.downloads.appending(path: component.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path), try sha256(of: dest) == component.sha256.lowercased() {
            return dest
        }
        // Named by checksum so two installs sharing a basename (or an asset that changed under
        // the same name) never append into each other's file.
        let partial = dest.appendingPathExtension("\(component.sha256.prefix(12)).partial")
        let etagFile = dest.appendingPathExtension("\(component.sha256.prefix(12)).etag")
        let expected = Int64(component.size ?? 0)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await fetch(component.url, into: partial, etagFile: etagFile, session: session) { received, total in
                    progress?(name, received, total > 0 ? total : expected)
                }
                lastError = nil
                break
            } catch {
                // A stop from the user is not a transient network failure: no retry, the
                // partial file stays for the next attempt.
                if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { throw error }
                lastError = error
                if attempt < 3 { try? await Task.sleep(for: .seconds([2, 5][attempt - 1])) }
            }
        }
        if let lastError { throw lastError }

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: partial, to: dest)
        try? FileManager.default.removeItem(at: etagFile)
        // Partials of other versions of the same file are dead weight once this one verified.
        if let siblings = try? FileManager.default.contentsOfDirectory(at: paths.downloads, includingPropertiesForKeys: nil) {
            for f in siblings where f.lastPathComponent.hasPrefix(dest.lastPathComponent + ".") && (f.pathExtension == "partial" || f.pathExtension == "etag") {
                try? FileManager.default.removeItem(at: f)
            }
        }
        let actual = try sha256(of: dest)
        guard actual == component.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: dest)
            throw HighballError.checksumMismatch(file: dest.lastPathComponent, expected: component.sha256, actual: actual)
        }
        progress?(name, expected > 0 ? expected : 1, expected > 0 ? expected : 1)
        return dest
    }

    /// One attempt: append to `partial` from its current size when the server honours the range,
    /// restart from zero when it does not (or the ETag changed). Streams to disk, reporting every
    /// ~2 MB (the app once showed a blank sheet for a whole 270 MB download).
    func fetch(_ url: URL, into partial: URL, etagFile: URL, session: URLSession,
               onProgress: @escaping (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        let have = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        let etag = try? String(contentsOf: etagFile, encoding: .utf8)
        var request = URLRequest(url: url)
        if let range = DownloadResume.rangeHeaders(partialBytes: have, etag: etag) {
            for (k, v) in range { request.setValue(v, forHTTPHeaderField: k) }
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HighballError.invalid("no HTTP response for \(url.absoluteString)") }
        let decision = DownloadResume.decide(status: http.statusCode, partialBytes: have)
        switch decision {
        case .failed: throw HighballError.invalid("HTTP \(http.statusCode) for \(url.absoluteString)")
        case .restart: try? fm.removeItem(at: partial)
        case .append: break
        }
        if let newTag = http.value(forHTTPHeaderField: "ETag") { try? newTag.write(to: etagFile, atomically: true, encoding: .utf8) }
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written = decision == .append ? have : 0
        // A chunked response reports -1; then the caller's manifest size drives the bar.
        let total: Int64 = http.expectedContentLength < 0 ? 0 : (decision == .append ? have + http.expectedContentLength : http.expectedContentLength)
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var lastReported: Int64 = written
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer); written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if written - lastReported >= 2_000_000 { lastReported = written; onProgress(written, total) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); written += Int64(buffer.count) }
        onProgress(written, total)
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
