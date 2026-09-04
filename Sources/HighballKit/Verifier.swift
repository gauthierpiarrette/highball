import CoreGraphics
import Foundation
import ImageIO

/// Automated compatibility runs: launch a Steam game under a renderer, watch whether it
/// survives and actually draws something, and record a provenance-complete verdict.
public struct VerifyOutcome: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable { case renders, blackScreen, crashed, neverStarted }
    public var appid: Int
    public var title: String
    public var renderer: Renderer
    public var verdict: Verdict
    public var secondsAlive: Int
    public var meanLuminance: Double
    public var date: String
    public var engine: String
    public var chip: String
    public var macos: String
    public var log: String
    /// Which Direct3D implementation actually served the game, from the per-process logs the
    /// overlays write: "dxmt", "dxvk", or "wined3d" when neither wrote one during the run
    /// (Wine's own Direct3D, or a game drawing with Vulkan or OpenGL directly). Optional so
    /// older result lines still decode.
    public var served: String?
    /// False when a renderer overlay was asked for and Wine's own Direct3D served instead: the
    /// engine ignored the overlay (2026-09-04: a tree without WINEDLLPATH_PREPEND support passed
    /// every liveness check while never running DXMT or DXVK once).
    public var overlayApplied: Bool?
}

public struct Verifier {
    public let paths: HighballPaths
    public let engine: InstalledEngine
    public let bottle: Bottle

    public init(paths: HighballPaths = HighballPaths(), engine: InstalledEngine, bottle: Bottle) {
        self.paths = paths; self.engine = engine; self.bottle = bottle
    }

    /// Kills the bottle, launches `game` through a silent Steam under `renderer`, waits for the
    /// game process, samples the screen, and classifies the outcome.
    public func run(game: SteamGame, renderer: Renderer, runSeconds: Int = 90, log: (@Sendable (String) -> Void)? = nil) async throws -> VerifyOutcome {
        // Wine processes show Windows-style command lines (backslashes); cover both separators.
        let markers = ["steamapps/common/\(game.installdir)/", "steamapps\\common\\\(game.installdir)\\"]
        func gameAlive() -> Bool {
            guard let ps = try? Shell.capture("/bin/ps", ["axww"]) else { return false }
            return markers.contains { ps.contains($0) }
        }
        // Keep the display awake for the whole observation (screenshots of a sleeping display are black).
        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = ["-diu", "-t", String(runSeconds + 420)]
        try? caffeinate.run()
        defer { caffeinate.terminate() }

        // Cold start so the renderer/sync environment actually applies.
        try? WineRunner(paths: paths, engine: engine, bottle: bottle).kill()
        try? await Task.sleep(for: .seconds(8))

        let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
        let steam = bottle.driveC.appending(path: "Program Files (x86)/Steam/steam.exe")
        log?("[\(game.name)] launching via silent Steam (\(renderer.rawValue))…")
        // DXMT at info level writes its per-process log like DXVK does; those files, and when
        // they were written, are what attributes the verdict.
        let runStart = Date()
        let launch = Task {
            try await runner.start(steam, arguments: ["-silent", "-applaunch", String(game.appid)], renderer: renderer,
                                   extraEnvironment: ["DXMT_LOG_LEVEL": "info"])
        }

        // Wait up to 6 minutes for the game process (cold silent Steam needs ~2 min first).
        var waited = 0
        while !gameAlive() && waited < 360 { try await Task.sleep(for: .seconds(5)); waited += 5 }
        let started = gameAlive()
        var alive = 0
        var luminances: [Double] = []
        if started {
            log?("[\(game.name)] game process up after \(waited)s; observing \(runSeconds)s…")
            while alive < runSeconds && gameAlive() {
                try await Task.sleep(for: .seconds(10)); alive += 10
                if alive >= 30, let lum = Self.screenLuminance() { luminances.append(lum) }
            }
        }
        let survived = gameAlive()
        // Tear down.
        try? WineRunner(paths: paths, engine: engine, bottle: bottle).kill()
        launch.cancel()
        let served = Self.servedImplementation(logsDirectory: bottle.driveC.appending(path: "highball/logs"), since: runStart)
        // Every renderer but wined3d routes Direct3D 9 through the d9vk overlay, so "dxvk" under a
        // dxmt run is still an overlay; only Wine's own implementation means the ask was ignored.
        let overlayApplied: Bool? = renderer == .wined3d ? nil : served != "wined3d"

        let meanLum = luminances.isEmpty ? 0 : luminances.reduce(0, +) / Double(luminances.count)
        let verdict: VerifyOutcome.Verdict =
            !started ? .neverStarted :
            (!survived && alive < runSeconds ? .crashed :
            (meanLum < 0.02 ? .blackScreen : .renders))

        let chip = (try? Shell.capture("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
        let macos = (try? Shell.capture("/usr/bin/sw_vers", ["-productVersion"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
        let outcome = VerifyOutcome(appid: game.appid, title: game.name, renderer: renderer, verdict: verdict,
                                    secondsAlive: alive, meanLuminance: (meanLum * 1000).rounded() / 1000,
                                    date: ISO8601DateFormatter().string(from: Date()),
                                    engine: engine.id, chip: chip, macos: macos, log: "",
                                    served: served, overlayApplied: overlayApplied)
        try append(outcome)
        let via = overlayApplied == false ? " via \(served), OVERLAY NOT APPLIED" : " via \(served)"
        log?("[\(game.name)] \(renderer.rawValue): \(verdict.rawValue) (alive \(alive)s, luminance \(outcome.meanLuminance))\(via)")
        return outcome
    }

    /// Names the Direct3D implementation that served the run from the per-process logs the
    /// overlays write into the bottle (DXVK and DXMT both do, under `highball/logs`), ignoring
    /// Steam's own helpers. A file written during the run whose header names DXVK means dxvk,
    /// one naming DXMT means dxmt; no such file means Wine's own Direct3D served (or the game
    /// drew with Vulkan or OpenGL directly), which is reported as wined3d. Wine's load trace
    /// cannot do this job: it names overlay builtins by their Windows path.
    public static func servedImplementation(logsDirectory: URL, since: Date) -> String {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return "wined3d" }
        var found: [String] = []
        for f in files where f.pathExtension == "log" {
            let name = f.lastPathComponent.lowercased()
            guard name.contains("_d3d"), !name.hasPrefix("steam"), !name.hasPrefix("gameoverlayui") else { continue }
            guard let modified = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified >= since else { continue }
            guard let head = try? String(contentsOf: f, encoding: .utf8).prefix(2000).lowercased() else { continue }
            if head.contains("dxmt") { found.append("dxmt") } else if head.contains("dxvk") { found.append("dxvk") }
        }
        if found.contains("dxmt") { return "dxmt" }
        if found.contains("dxvk") { return "dxvk" }
        return "wined3d"
    }

    func append(_ o: VerifyOutcome) throws {
        try paths.ensure()
        let file = paths.logs.appending(path: "verify-results.jsonl")
        let line = String(decoding: try JSONEncoder().encode(o), as: UTF8.self) + "\n"
        if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try line.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Mean luminance of the main display, 0…1. Requires Screen Recording permission and an awake display.
    public static func screenLuminance() -> Double? {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "hb-verify-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? Shell.run("/usr/sbin/screencapture", ["-x", "-t", "png", tmp.path])) != nil,
              let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
        guard let data = img.dataProvider?.data as Data? else { return nil }
        let bpp = img.bitsPerPixel / 8
        guard bpp >= 3, data.count >= bpp else { return nil }
        var total = 0.0; var count = 0
        for i in stride(from: 0, to: data.count - bpp, by: bpp) {
            total += (Double(data[i]) + Double(data[i + 1]) + Double(data[i + 2])) / (3 * 255)
            count += 1
        }
        return count > 0 ? total / Double(count) : nil
    }
}
