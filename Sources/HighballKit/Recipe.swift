import Foundation

/// A recipe is declarative data (JSON, CC0 in gin-db) describing how to install and configure
/// a launcher or game inside a bottle. Steps run in order; each is idempotent where possible.
public struct Recipe: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case launcher, game, tweak }

    public enum Step: Codable, Sendable {
        /// Download a file (verified if sha256 given) and run it inside the bottle.
        case installer(url: URL, sha256: String?, arguments: [String], label: String)
        /// `wine reg add`.
        case registry(key: String, name: String, type: String, data: String)
        /// Run winetricks verbs (unattended).
        case winetricks(verbs: [String])
        /// Set a persistent environment variable on the bottle.
        case environment(name: String, value: String)
        /// Set the bottle's renderer.
        case renderer(Renderer)
        /// Set the bottle's synchronization mode (none | esync | msync).
        case sync(SyncMode)
        /// Write a text file inside drive_c.
        case file(path: String, contents: String)
        /// Add a pinned program to the bottle.
        case pin(Pin)
        /// Free-text instruction the UI surfaces to the user after install.
        case note(String)

        private enum CodingKeys: String, CodingKey { case type, url, sha256, arguments, label, key, name, value, valueType, data, verbs, renderer, sync, path, contents, pin, text }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "installer":
                self = .installer(url: try c.decode(URL.self, forKey: .url),
                                  sha256: try c.decodeIfPresent(String.self, forKey: .sha256),
                                  arguments: try c.decodeIfPresent([String].self, forKey: .arguments) ?? [],
                                  label: try c.decodeIfPresent(String.self, forKey: .label) ?? "installer")
            case "registry":
                self = .registry(key: try c.decode(String.self, forKey: .key), name: try c.decode(String.self, forKey: .name),
                                 type: try c.decodeIfPresent(String.self, forKey: .valueType) ?? "REG_DWORD", data: try c.decode(String.self, forKey: .data))
            case "winetricks": self = .winetricks(verbs: try c.decode([String].self, forKey: .verbs))
            case "environment": self = .environment(name: try c.decode(String.self, forKey: .name), value: try c.decode(String.self, forKey: .value))
            case "renderer": self = .renderer(try c.decode(Renderer.self, forKey: .renderer))
            case "sync": self = .sync(try c.decode(SyncMode.self, forKey: .sync))
            case "file": self = .file(path: try c.decode(String.self, forKey: .path), contents: try c.decode(String.self, forKey: .contents))
            case "pin": self = .pin(try c.decode(Pin.self, forKey: .pin))
            case "note": self = .note(try c.decode(String.self, forKey: .text))
            case let other: throw HighballError.invalid("unknown recipe step type '\(other)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .installer(url, sha256, arguments, label):
                try c.encode("installer", forKey: .type); try c.encode(url, forKey: .url)
                try c.encodeIfPresent(sha256, forKey: .sha256); try c.encode(arguments, forKey: .arguments); try c.encode(label, forKey: .label)
            case let .registry(key, name, type, data):
                try c.encode("registry", forKey: .type); try c.encode(key, forKey: .key); try c.encode(name, forKey: .name)
                try c.encode(type, forKey: .valueType); try c.encode(data, forKey: .data)
            case let .winetricks(verbs): try c.encode("winetricks", forKey: .type); try c.encode(verbs, forKey: .verbs)
            case let .environment(name, value): try c.encode("environment", forKey: .type); try c.encode(name, forKey: .name); try c.encode(value, forKey: .value)
            case let .renderer(r): try c.encode("renderer", forKey: .type); try c.encode(r, forKey: .renderer)
            case let .sync(m): try c.encode("sync", forKey: .type); try c.encode(m, forKey: .sync)
            case let .file(path, contents): try c.encode("file", forKey: .type); try c.encode(path, forKey: .path); try c.encode(contents, forKey: .contents)
            case let .pin(p): try c.encode("pin", forKey: .type); try c.encode(p, forKey: .pin)
            case let .note(t): try c.encode("note", forKey: .type); try c.encode(t, forKey: .text)
            }
        }
    }

    public struct KnownIssue: Codable, Sendable {
        public var symptom: String
        public var cause: String?
        public var fix: String?
    }

    public struct Verification: Codable, Sendable {
        public var date: String
        public var engine: String
        public var macos: String
        public var chip: String
        public var result: String
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var requires: [String]?
    public var renderer: Renderer?
    public var steps: [Step]
    public var knownIssues: [KnownIssue]?
    public var lastVerified: Verification?

    public static func load(from url: URL) throws -> Recipe {
        try JSONDecoder.gin.decode(Recipe.self, from: Data(contentsOf: url))
    }
}

/// Applies a recipe to a bottle.
public struct RecipeRunner: Sendable {
    public let paths: HighballPaths
    public let engine: InstalledEngine
    public var bottle: Bottle
    public let store: EngineStore

    public init(paths: HighballPaths = HighballPaths(), engine: InstalledEngine, bottle: Bottle) {
        self.paths = paths; self.engine = engine; self.bottle = bottle; self.store = EngineStore(paths: paths)
    }

    /// Runs every step. Returns the notes the UI should show afterwards.
    public mutating func apply(_ recipe: Recipe, log: (@Sendable (String) -> Void)? = nil) async throws -> [String] {
        var notes: [String] = []
        if let r = recipe.renderer { bottle.settings.renderer = r }
        for (i, step) in recipe.steps.enumerated() {
            log?("[\(recipe.id)] step \(i + 1)/\(recipe.steps.count)")
            let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
            switch step {
            case let .installer(url, sha256, arguments, label):
                let component = EngineManifest.Component(kind: "installer", url: url, sha256: sha256 ?? "", size: nil, license: nil, optional: nil, acceptance: nil, extract: nil, note: nil, version: nil)
                let file: URL
                if sha256 != nil {
                    file = try await store.download(component, name: label)
                } else {
                    file = try await downloadUnverified(url)
                }
                let isMSI = file.pathExtension.lowercased() == "msi" || url.lastPathComponent.lowercased().contains(".msi")
                let wineArgs = isMSI ? ["msiexec", "/i", file.path, "/qn"] + arguments : [file.path] + arguments
                let result = try await runner.run(wineArgs, renderer: .wined3d, label: label, onOutput: log)
                guard result.exitStatus == 0 else {
                    throw HighballError.processFailed(command: label, status: result.exitStatus, output: "see \(result.log.path)")
                }
            case let .registry(key, name, type, data):
                try await runner.regAdd(key: key, name: name, type: type, data: data)
            case let .winetricks(verbs):
                guard let wt = engine.winetricks else { throw HighballError.missing("winetricks in engine \(engine.id)") }
                let env = try bottle.environment(engine: engine, renderer: .wined3d, extra: ["WINE": engine.wineBinary.path, "WINESERVER": engine.wineserverBinary.path])
                try Shell.run("/bin/sh", [wt.path, "--unattended"] + verbs, env: env)
            case let .environment(name, value):
                bottle.settings.environment[name] = value
            case let .renderer(r):
                bottle.settings.renderer = r
            case let .sync(m):
                bottle.settings.sync = m
            case let .file(path, contents):
                let url = bottle.driveC.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            case let .pin(p):
                if !bottle.settings.pins.contains(where: { $0.path == p.path }) { bottle.settings.pins.append(p) }
            case let .note(t):
                notes.append(t)
            }
        }
        if !bottle.settings.recipes.contains(recipe.id) { bottle.settings.recipes.append(recipe.id) }
        try bottle.save()
        return notes
    }

    private func downloadUnverified(_ url: URL) async throws -> URL {
        try paths.ensure()
        let dest = paths.downloads.appending(path: url.lastPathComponent)
        let (tmp, _) = try await URLSession.shared.download(from: url)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
