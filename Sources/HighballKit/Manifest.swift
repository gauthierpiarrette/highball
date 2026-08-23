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
    public var orderedComponents: [(name: String, component: Component)] {
        components.sorted { a, b in
            if a.value.isOptional != b.value.isOptional { return !a.value.isOptional }
            return a.key < b.key
        }.map { ($0.key, $0.value) }
    }
}
