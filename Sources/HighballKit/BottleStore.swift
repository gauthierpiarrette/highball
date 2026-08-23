import Foundation

public struct BottleStore: Sendable {
    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    public func list() throws -> [Bottle] {
        guard FileManager.default.fileExists(atPath: paths.bottles.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: paths.bottles, includingPropertiesForKeys: nil)
            .compactMap { try? Bottle.load($0) }
            .sorted { $0.name < $1.name }
    }

    public func get(_ name: String) throws -> Bottle {
        try Bottle.load(paths.bottle(name))
    }

    /// Creates the directory + gin.json, then runs `wineboot -u` to populate the prefix.
    public func create(name: String, engine: InstalledEngine, renderer: Renderer = .dxmt, windowsVersion: WindowsVersion = .win10) async throws -> Bottle {
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
        return bottle
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
