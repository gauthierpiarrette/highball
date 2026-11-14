import CryptoKit
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

    /// Whether this engine is meant for the given macOS version (numeric compare of `minMacOS`,
    /// "27.0" against "26.6.2" and so on). An engine measured only on a newer macOS says so in
    /// its floor and is then neither offered nor installed on an older one (highball#85).
    public func runs(onMacOS version: String) -> Bool {
        let parse: (String) -> [Int] = { $0.split(separator: ".").map { Int($0) ?? 0 } }
        let floor = parse(minMacOS), have = parse(version)
        for i in 0..<max(floor.count, have.count) {
            let f = i < floor.count ? floor[i] : 0, h = i < have.count ? have[i] : 0
            if h != f { return h > f }
        }
        return true
    }

    /// This Mac's macOS version as "major.minor.patch".
    public static var currentMacOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    public var requires: [String]?
    public var notes: [String]?
    /// Who may see this engine (EngineChannels): nil for everyone, "beta" for installs that get
    /// beta builds, "preview" only where the preview key is set. An engine line still being proven
    /// ships in the app this way, and opening it to players is a change to this field.
    public var channel: String?

    // MARK: Architecture

    /// The Unix side of this engine is native arm64 code: Wine's own builtins are ARM64X images in
    /// `aarch64-windows`, x86 and x86-64 programs run through FEX inside Wine, and the loader is
    /// Highball's signed helper (WineLoaderHelper) rather than the engine's own binary. Every other
    /// engine is Intel code that runs under Rosetta (private/notes/rosetta-transition-plan.md).
    public var isNativeARM64: Bool { arch == "arm64" }
    /// Whether the engine needs Rosetta at all. The Intel engines say so in `requires`; an engine
    /// that does not is installed, offered and run without a word about Rosetta.
    public var requiresRosetta: Bool { (requires ?? []).contains("rosetta2") }
    /// The directory under `lib/wine` of the Unix halves of Wine's builtins (`ntdll.so`, `winemac.so`).
    public var unixLibDir: String { Self.unixLibDir(arch: arch) }
    /// The directory under `lib/wine` of the 64-bit PE builtins and of a renderer overlay's 64-bit
    /// DLLs: ARM64X images on an arm64 engine, which carry the ARM64EC code x86-64 programs call
    /// into, x86-64 images otherwise.
    public var pe64LibDir: String { Self.pe64LibDir(arch: arch) }
    /// The 32-bit PE builtins, the same directory on both: 32-bit programs run through WoW64.
    public static let pe32LibDir = "i386-windows"
    public static func unixLibDir(arch: String) -> String { arch == "arm64" ? "aarch64-unix" : "x86_64-unix" }
    public static func pe64LibDir(arch: String) -> String { arch == "arm64" ? "aarch64-windows" : "x86_64-windows" }
    /// Which Direct3D 9 a game gets in the automatic modes (DXMT, D3DMetal): nil attaches DXVK's
    /// d3d9 (the d9vk overlay) beside the Metal backend, "wined3d" leaves Direct3D 9 to Wine's
    /// own, because on this engine that is the fast path. Measured on the Wine 11 tree: Half-Life
    /// 2 131 fps on wined3d against 17 on DXVK's d3d9, Five Nights at Freddy's 40 fps on DXVK's
    /// d3d9 where the Wine 10 engine gives 76 (highball#198, 2026-09-25). The explicit DXVK mode
    /// keeps DXVK's d3d9 whatever this says: there Direct3D 9 through DXVK is the point (CS:GO
    /// Legacy's CSM check needs it, highball#21).
    public var direct3D9: String?
    /// Registry values this engine wants under HKCU\Software\Wine\AppDefaults\<exe>, per
    /// executable: value name to REG_SZ data. Highball mirrors them into every environment on the
    /// engine before a launch (WineRunner.syncEngineAppDefaults), so an environment that moved to
    /// the engine gets them without a recipe re-run. First use: on the Wine 11 tree Steam's browser
    /// (steamwebhelper.exe) composites on the GPU into steam.exe's window and DXVK presents that
    /// black, while the Wine 10 engine's Steam never touches Direct3D 11, so the engine asks for
    /// CommandLineAppend = --disable-gpu (patch 0006), the software path (highball#202, 2026-09-26).
    public var appDefaults: [String: [String: String]]?
    /// This engine can start a mapped Windows executable in its own macOS app bundle.
    public var nativeGameIdentity: Bool?
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

    /// The folder name of vkd3d-proton's pipeline cache for this engine build: the id plus eight hex
    /// digits over every component's checksum. A rebuilt component (a patched MoltenVK under the same
    /// version, a new renderer build) gets a fresh cache instead of reusing pipelines another build
    /// compiled, which is how stale caches survived MoltenVK rebuilds (backlog B2).
    public var vkd3dCacheKey: String {
        let fingerprint = components.keys.sorted().map { "\($0)=\(components[$0]!.sha256)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(id)-\(digest.prefix(8))"
    }

    /// What installing this engine downloads, each archive once: two components can unpack
    /// different folders of one archive, and the store fetches it once (EngineStore.download).
    public var downloadBytes: Int {
        var seen = Set<URL>()
        return components.values.sorted { $0.url.absoluteString < $1.url.absoluteString }
            .reduce(0) { total, c in seen.insert(c.url).inserted ? total + (c.size ?? 0) : total }
    }

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

    /// The line an engine id belongs to, the id without its revision (`x64-crossover26.3-r7` is
    /// `x64-crossover26.3`), or nil for an id without one.
    public static func line(of id: String) -> String? {
        guard let range = id.range(of: #"-r(\d+)$"#, options: .regularExpression) else { return nil }
        return String(id[..<range.lowerBound])
    }

    /// True when `current` is the engine `id` names or a later revision of its line.
    public static func isAtOrAfter(current: String, wanted id: String) -> Bool {
        if current == id { return true }
        guard let l = line(of: current), l == line(of: id),
              let c = revision(of: current), let w = revision(of: id) else { return false }
        return c >= w
    }

    /// True when a bottle on `current` already has everything `wanted` would bring: the same
    /// engine, or a later revision of its line carrying every component it has.
    ///
    /// A later revision counts whether or not it rebuilt Wine. Comparing Wine digests made a
    /// bottle on r12, whose Wine was rebuilt with more patches, be offered r11 for The Last
    /// Flame's pin, a downgrade. The component check keeps two lines that share an id apart:
    /// the GPTK 4 revisions of the Wine 10 tree add a D3DMetal component the default ones lack,
    /// so the default r13 never passes for the GPTK 4 r6.
    public static func satisfies(current: EngineManifest, wanted: EngineManifest) -> Bool {
        guard isAtOrAfter(current: current.id, wanted: wanted.id) else { return false }
        return Set(wanted.components.keys).isSubset(of: current.components.keys)
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
