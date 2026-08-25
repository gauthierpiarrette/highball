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

    /// Creates the directory + gin.json, then runs `wineboot -u` to populate the prefix.
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
        if windowsVersion != .win10 { try await runner.setWindowsVersion(windowsVersion) }
        try? await runner.setGpuIdentity()
        return bottle
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
