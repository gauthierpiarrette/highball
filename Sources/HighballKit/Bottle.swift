import Foundation

/// Graphics backend applied to a bottle (or overridden per program).
public enum Renderer: String, Codable, CaseIterable, Sendable {
    /// Wine's own D3D-on-OpenGL. Slow; last resort.
    case wined3d
    /// D3D10/11 → Metal. Gin's default.
    case dxmt
    /// Apple's D3D11/12 → Metal. Only D3D12 path. Apple-licensed, optional download.
    case d3dmetal
    /// D3D9/10/11 → Vulkan → MoltenVK. Use for D3D9 titles.
    case dxvk

    /// Environment contributed by this renderer, given the engine that hosts it.
    public func environment(engine: InstalledEngine) throws -> [String: String] {
        var env: [String: String] = [:]
        switch self {
        case .wined3d:
            return env
        case .dxmt:
            guard let dir = engine.rendererDir("dxmt") else { throw HighballError.missing("dxmt renderer in engine \(engine.id)") }
            env["WINEDLLPATH_PREPEND"] = dir.appending(path: "wine").path
        case .d3dmetal:
            guard let dir = engine.rendererDir("d3dmetal") else { throw HighballError.missing("d3dmetal renderer in engine \(engine.id) (optional component not installed?)") }
            let external = dir.appending(path: "external").path
            env["WINEDLLPATH_PREPEND"] = dir.appending(path: "wine").path
            env["CX_D3DMETALPATH"] = external
            env["DYLD_FALLBACK_LIBRARY_PATH+"] = external
            env["DYLD_FALLBACK_FRAMEWORK_PATH+"] = external
        case .dxvk:
            guard let dir = engine.rendererDir("dxvk") else { throw HighballError.missing("dxvk renderer in engine \(engine.id)") }
            env["WINEDLLPATH_PREPEND"] = dir.appending(path: "wine").path
            env["WINEDLLOVERRIDES+"] = "dxgi,d3d9,d3d10core,d3d11=n,b"
        }
        return env
    }
}

public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case win7, win8, win81, win10, win11
}

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    case none, esync, msync
}

/// A pinned program inside a bottle.
public struct Pin: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var name: String
    /// Path relative to the bottle's `drive_c`.
    public var path: String
    public var arguments: [String] = []
    public var environment: [String: String] = [:]
    public var renderer: Renderer? = nil

    public init(name: String, path: String, arguments: [String] = [], environment: [String: String] = [:], renderer: Renderer? = nil) {
        self.name = name; self.path = path; self.arguments = arguments; self.environment = environment; self.renderer = renderer
    }
}

/// Persisted as `<bottle>/gin.json`.
public struct BottleSettings: Codable, Sendable {
    public var formatVersion: Int = 1
    public var name: String
    public var engineID: String
    public var renderer: Renderer = .dxmt
    public var windowsVersion: WindowsVersion = .win10
    public var sync: SyncMode = .msync
    public var metalHUD: Bool = false
    public var advertiseAVX: Bool = false
    /// DXVK async pipeline compilation — big shader-stutter relief, minor risk of artifacts.
    public var dxvkAsync: Bool = true
    /// Cap the frame rate (0 = uncapped). Applied per renderer (DXVK_FRAME_RATE / DXMT_CONFIG).
    public var fpsCap: Int = 0
    /// Wine Mac driver Retina mode: expose native pixels + 192 DPI (applied via registry on toggle).
    public var retinaMode: Bool = false
    public var environment: [String: String] = [:]
    public var pins: [Pin] = []
    public var recipes: [String] = []
    public var created: Date = Date()

    public init(name: String, engineID: String) {
        self.name = name
        self.engineID = engineID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        name = try c.decode(String.self, forKey: .name)
        engineID = try c.decode(String.self, forKey: .engineID)
        renderer = try c.decodeIfPresent(Renderer.self, forKey: .renderer) ?? .dxmt
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? .win10
        sync = try c.decodeIfPresent(SyncMode.self, forKey: .sync) ?? .msync
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? false
        dxvkAsync = try c.decodeIfPresent(Bool.self, forKey: .dxvkAsync) ?? true
        fpsCap = try c.decodeIfPresent(Int.self, forKey: .fpsCap) ?? 0
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? false
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        pins = try c.decodeIfPresent([Pin].self, forKey: .pins) ?? []
        recipes = try c.decodeIfPresent([String].self, forKey: .recipes) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
}

public struct Bottle: Sendable {
    public let url: URL
    public var settings: BottleSettings

    public var name: String { settings.name }
    public var driveC: URL { url.appending(path: "drive_c", directoryHint: .isDirectory) }
    public var settingsURL: URL { url.appending(path: "bottle.json") }

    public init(url: URL, settings: BottleSettings) {
        self.url = url
        self.settings = settings
    }

    public static func load(_ url: URL) throws -> Bottle {
        let modern = url.appending(path: "bottle.json")
        let legacy = url.appending(path: "gin.json")
        let file = FileManager.default.fileExists(atPath: modern.path) ? modern : legacy
        let data = try Data(contentsOf: file)
        let settings = try JSONDecoder.gin.decode(BottleSettings.self, from: data)
        return Bottle(url: url, settings: settings)
    }

    public func save() throws {
        try JSONEncoder.gin.encode(settings).write(to: settingsURL, options: .atomic)
    }

    /// Environment for running something in this bottle: engine base + bottle settings + renderer + extras.
    /// Keys ending in `+` are appended to an existing value with `:` (paths) or `;` (WINEDLLOVERRIDES).
    public func environment(engine: InstalledEngine, renderer: Renderer? = nil, extra: [String: String] = [:]) throws -> [String: String] {
        var env = engine.baseEnvironment()
        env["WINEPREFIX"] = url.path
        env["WINEDEBUG"] = "fixme-all"
        // Explicit 0s matter: Steam's CEF webhelper hangs under msync/esync on Wine 10 (see recipes/launchers/steam.json).
        switch settings.sync {
        case .none: env["WINEMSYNC"] = "0"; env["WINEESYNC"] = "0"
        case .esync: env["WINEESYNC"] = "1"; env["WINEMSYNC"] = "0"
        case .msync: env["WINEMSYNC"] = "1"; env["WINEESYNC"] = "0"
        }
        if settings.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if settings.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        let r = renderer ?? settings.renderer
        if r == .dxvk, settings.dxvkAsync { env["DXVK_ASYNC"] = "1" }
        if settings.fpsCap > 0 {
            switch r {
            case .dxvk: env["DXVK_FRAME_RATE"] = String(settings.fpsCap)
            case .dxmt: env["DXMT_CONFIG"] = "d3d11.preferredMaxFrameRate=\(settings.fpsCap);"
            default: break
            }
        }
        merge(&env, settings.environment)
        merge(&env, try (renderer ?? settings.renderer).environment(engine: engine))
        merge(&env, extra)
        return env
    }

    private func merge(_ env: inout [String: String], _ add: [String: String]) {
        for (k, v) in add {
            if k.hasSuffix("+") {
                let key = String(k.dropLast())
                let sep = key == "WINEDLLOVERRIDES" ? ";" : ":"
                env[key] = [v, env[key]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: sep)
            } else {
                env[k] = v
            }
        }
    }

    /// Convert a Windows path like `C:\Program Files (x86)\Steam\steam.exe` to a file URL inside the bottle.
    public func resolve(windowsPath: String) -> URL {
        var p = windowsPath
        if p.lowercased().hasPrefix("c:") { p = String(p.dropFirst(2)) }
        p = p.replacingOccurrences(of: "\\", with: "/")
        if p.hasPrefix("/") { p.removeFirst() }
        return driveC.appending(path: p)
    }
}

extension JSONEncoder {
    static var gin: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var gin: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
