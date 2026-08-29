import Foundation

public struct BottleStore: Sendable {
    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    public func list() throws -> [Bottle] {
        guard FileManager.default.fileExists(atPath: paths.bottles.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: paths.bottles, includingPropertiesForKeys: nil)
            .compactMap { url -> Bottle? in
                guard var b = try? Bottle.load(url) else { return nil }
                // The folder is the bottle's identity (get/delete resolve by folder). A copied
                // folder keeps the old internal name, which crashed the app and confused lookups
                // (issue #13) — reconcile so "play copy" is simply a bottle called "play copy".
                if b.settings.name != url.lastPathComponent {
                    b.settings.name = url.lastPathComponent
                    try? b.save()
                }
                return b
            }
            .sorted { $0.name < $1.name }
    }

    public func get(_ name: String) throws -> Bottle {
        try Bottle.load(paths.bottle(name))
    }

    /// Returns a human-readable problem with a bottle name, or nil if it is usable.
    /// The bottle directory becomes part of the Wine prefix's Windows-side path (Z:\…\bottles\<name>\),
    /// so characters Windows forbids in paths break prefix initialization outright:
    /// wineboot exits 53 with "could not load kernel32.dll, status c0000135" (issue #12).
    public static func nameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "The bottle name is empty." }
        if trimmed.contains(where: { #"\/:*?"<>|"#.contains($0) }) {
            return #"A bottle name can't contain \ / : * ? " < > | — Windows paths forbid them, which would break the bottle."#
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "The bottle name contains control characters."
        }
        if trimmed.hasPrefix(".") { return "A bottle name can't start with a dot." }
        if trimmed.hasSuffix(".") { return "A bottle name can't end with a dot." }
        if trimmed.count > 64 { return "The bottle name is too long (64 characters max)." }
        return nil
    }

    /// Creates the directory + bottle.json, then runs `wineboot -u` to populate the prefix.
    public func create(name rawName: String, engine: InstalledEngine, renderer: Renderer = .dxmt, windowsVersion: WindowsVersion = .win10) async throws -> Bottle {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let problem = Self.nameProblem(name) { throw HighballError.invalid(problem) }
        try paths.ensure()
        let url = paths.bottle(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw HighballError.invalid("bottle '\(name)' already exists") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var settings = BottleSettings(name: name, engineID: engine.id)
        settings.renderer = renderer
        settings.windowsVersion = windowsVersion
        let bottle = Bottle(url: url, settings: settings)
        try bottle.save()
        let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
        let result = try await runner.wineboot()
        guard result.exitStatus == 0 else {
            throw HighballError.processFailed(command: "wineboot -u", status: result.exitStatus, output: "see \(result.log.path)")
        }
        do {
            try await Self.ensureWoW64(runner: runner, bottle: bottle, log: result.log)
        } catch {
            // Don't strand a half-built bottle: it can never run a 32-bit installer, and leaving
            // it behind means retrying with the same name hits "bottle already exists".
            try? runner.kill()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        if windowsVersion != .win10 { try await runner.setWindowsVersion(windowsVersion) }
        try? await runner.setGpuIdentity()
        try? await runner.setServiceTimeout()
        return bottle
    }

    /// The 32-bit half of a prefix, and whether it is actually there.
    ///
    /// Wine populates `syswow64` by launching a 32-bit rundll32 for the inf's Wow64Install
    /// section; if that launch fails, wineboot's loop skips the wait and **still exits 0**
    /// (verified in wineboot.c). So an exit-code check cannot tell a working bottle from one
    /// with no 32-bit support — which is exactly issue #37: bottles create "fine", then every
    /// installer dies with `could not load kernel32.dll, status c0000135`, because Wine will
    /// not fall back to the engine's i386-windows dlls outside prefix bootstrap. Most Windows
    /// installers are 32-bit, so such a bottle can install nothing at all.
    public static func woW64Kernel32(in bottle: Bottle) -> URL {
        bottle.driveC.appending(path: "windows/syswow64/kernel32.dll")
    }

    /// Verifies the 32-bit half exists, retrying wineboot once before giving up. A failure
    /// here is reported at bottle creation, where it is actionable, instead of surfacing later
    /// as an opaque error on every install.
    public static func ensureWoW64(runner: WineRunner, bottle: Bottle, log: URL) async throws {
        if FileManager.default.fileExists(atPath: woW64Kernel32(in: bottle).path) { return }
        _ = try? await runner.wineboot(force: true)
        guard FileManager.default.fileExists(atPath: woW64Kernel32(in: bottle).path) else {
            // Wine only falls back to the engine's 32-bit builtins while a prefix is
            // bootstrapping, so a prefix that missed this step cannot be repaired in place
            // (verified: re-running wineboot, forced or not, leaves syswow64 empty). A fresh
            // bottle is the fix, which is why creation fails here rather than later.
            throw HighballError.invalid("""
                Windows 32-bit support didn't finish setting up in this bottle, so most \
                installers can't run in it (they fail with "could not load kernel32.dll"). \
                Please create the bottle again. If it happens every time, report it with this \
                log attached and we'll dig in: \(log.path)
                """)
        }
    }

    /// Copies a bottle under a new name (default "<name> copy", uniquified). Callers should stop
    /// the bottle's wineserver first so the registry files on disk are flushed and consistent.
    public func duplicate(_ name: String, as newName: String? = nil) throws -> Bottle {
        let source = try get(name)
        var target = newName ?? "\(name) copy"
        if newName == nil {
            var i = 2
            while FileManager.default.fileExists(atPath: paths.bottle(target).path) { target = "\(name) copy \(i)"; i += 1 }
        }
        if let problem = Self.nameProblem(target) { throw HighballError.invalid(problem) }
        let dest = paths.bottle(target)
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw HighballError.invalid("bottle '\(target)' already exists") }
        try FileManager.default.copyItem(at: source.url, to: dest)
        var copy = try Bottle.load(dest)
        copy.settings.name = target
        try copy.save()
        return copy
    }

    public func delete(_ name: String) throws {
        let url = paths.bottle(name)
        guard FileManager.default.fileExists(atPath: url.appending(path: "bottle.json").path) else {
            throw HighballError.missing("bottle '\(name)'")
        }
        try FileManager.default.removeItem(at: url)
    }

    public func update(_ bottle: Bottle) throws { try bottle.save() }
}
