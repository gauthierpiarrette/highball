import Foundation

/// An engine manifest describes every binary Gin downloads to assemble one engine.
/// Gin ships manifests, never binaries. See `spike/engine-manifest.json` for the
/// first real one.
public struct EngineManifest: Codable, Sendable, Identifiable {
    public struct Extract: Codable, Sendable {
        /// Path inside the archive to take (e.g. `Template-1.0.11.app/Contents/Frameworks`).
        public var subpath: String?
        /// Single top-level directory to strip (e.g. `wswine.bundle`). Equivalent to `subpath` for the common case.
        public var strip: String?
        /// Destination relative to the engine directory (`engine`, `frameworks`, `renderers/dxmt/wine`).
        public var into: String
    }

    public struct Component: Codable, Sendable {
        public var kind: String
        public var url: URL
        public var sha256: String
        public var size: Int?
        public var license: String?
        public var optional: Bool?
        /// Identifier of a license the user must accept before this component is downloaded.
        public var acceptance: String?
        public var extract: Extract?
        public var note: String?
        public var version: String?
        /// Install order among components of the same optionality (default 0, lower first).
        /// A component that must land on top of another one's files, like a patched
        /// MoltenVK replacing the runtime's, declares a higher order than the one it overrides.
        public var order: Int?
        /// True when installing this component changes what `wineboot` writes into a prefix
        /// (a new builtin DLL needs its placeholder in system32/syswow64 before a game can load
        /// it by its system path). A bottle moving to an engine that adds such a component gets
        /// its Windows setup re-run even when the Wine build is the same.
        public var refreshesPrefix: Bool?

        public var isOptional: Bool { optional ?? false }
    }

    public var id: String
    public var displayName: String
    public var arch: String
    public var minMacOS: String
    public var requires: [String]?
    public var notes: [String]?
    public var components: [String: Component]
    public var baseEnv: [String: String]?
    /// License ids that gate optional renderers (e.g. `apple-gptk-license-2023-08-17` → d3dmetal).
    public var licenses: [String: License]?
    /// Filled in at install time with the license ids the user accepted.
    public var acceptedLicenses: [String]?

    public struct License: Codable, Sendable {
        public var applies: [String]?
        public var text: String?
        public var summary: String?
    }

    /// Renderer overlay names gated behind a license id.
    public static let gatedRenderers: [String: String] = ["d3dmetal": "apple-gptk-license-2023-08-17"]

    public static func load(from url: URL) throws -> EngineManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(EngineManifest.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Components in a deterministic install order: required first, then optional.
    /// Whether moving bottles from `old` to `new` needs `wineboot -u`: only when the Wine build
    /// itself changed. A component-only update (a patched MoltenVK on the same Wine) leaves the
    /// prefix as it is, and skipping the boot matters: a prefix with a real .NET install wedged
    /// in wineboot's 32-bit step on both engines during the r1 rollout test.
    public static func needsPrefixRefresh(from old: EngineManifest, to new: EngineManifest) -> Bool {
        guard let a = old.components["wine"]?.sha256, let b = new.components["wine"]?.sha256 else { return true }
        if a != b { return true }
        // Same Wine: only a component that asks for it (a new builtin DLL) forces the setup.
        return new.components.contains { name, c in
            c.refreshesPrefix == true && old.components[name]?.sha256 != c.sha256
        }
    }

    /// The revision number at the end of an engine id (`x64-crossover26.3-r7` is 7), or nil
    /// for an id without one. Revisions of one Wine build are cumulative: r7 carries everything
    /// r6 does, so a bottle on r7 already satisfies a recipe that names r6.
    public static func revision(of id: String) -> Int? {
        guard let range = id.range(of: #"-r(\d+)$"#, options: .regularExpression) else { return nil }
        return Int(id[range].dropFirst(2))
    }

    /// True when a bottle on `current` already has everything `wanted` would bring: the same
    /// engine, or a later revision of the same Wine build.
    public static func satisfies(current: EngineManifest, wanted: EngineManifest) -> Bool {
        if current.id == wanted.id { return true }
        guard let a = current.components["wine"]?.sha256, let b = wanted.components["wine"]?.sha256, a == b,
              let c = revision(of: current.id), let w = revision(of: wanted.id) else { return false }
        return c >= w
    }

    /// Same rule when the bottle's current engine cannot be resolved (its directory is gone):
    /// nothing is known about the Wine that built the prefix, so it is refreshed.
    public static func needsPrefixRefresh(from old: EngineManifest?, to new: EngineManifest) -> Bool {
        guard let old else { return true }
        return needsPrefixRefresh(from: old, to: new)
    }

    public var orderedComponents: [(name: String, component: Component)] {
        components.sorted { a, b in
            if a.value.isOptional != b.value.isOptional { return !a.value.isOptional }
            if (a.value.order ?? 0) != (b.value.order ?? 0) { return (a.value.order ?? 0) < (b.value.order ?? 0) }
            return a.key < b.key
        }.map { ($0.key, $0.value) }
    }
}
