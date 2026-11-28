import Foundation

extension EngineManifest {
    /// Checks the v0 installation contract without reading archives or changing disk state.
    /// Unknown JSON fields remain compatible; descriptive metadata is not a file inventory.
    /// Callers that only read installed manifests may decode without validating them again.
    public func validate() throws {
        guard Self.isManifestName(id) else {
            throw HighballError.failed("The engine ID must start with a letter or number and contain only letters, numbers, periods, underscores or hyphens.")
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HighballError.failed("The engine displayName must not be blank.")
        }
        guard arch == "x86_64" || arch == "arm64" else {
            throw HighballError.failed("This engine architecture is not supported. Use x86_64 or arm64.")
        }
        guard minMacOS.range(of: #"\A[0-9]+(?:\.[0-9]+){0,2}\z"#, options: .regularExpression) != nil,
              minMacOS.split(separator: ".").allSatisfy({ Int($0) != nil }) else {
            throw HighballError.failed("The engine minMacOS must be a numeric version, such as 14, 14.0 or 14.0.1.")
        }
        guard let wine = components["wine"] else {
            throw HighballError.failed("This manifest does not describe a complete engine. It must include a Wine component.")
        }
        guard wine.kind == "engine", !wine.isOptional, wine.extract?.into == "engine" else {
            throw HighballError.failed("The Wine component must have kind 'engine', be required, and extract into 'engine'.")
        }
        let kinds: Set<String> = ["engine", "frameworks", "runtime", "renderer", "patch", "tool"]
        for name in components.keys.sorted() {
            let component = components[name]!
            guard Self.isManifestName(name) else {
                throw HighballError.failed("The manifest contains an invalid component name.")
            }
            guard kinds.contains(component.kind) else {
                throw HighballError.failed("Component '\(name)' has an unsupported kind '\(component.kind)'.")
            }
            guard Self.isComponentURL(component.url) else {
                throw HighballError.failed("Component '\(name)' must use an HTTP or HTTPS URL with a host, or an absolute local file URL.")
            }
            guard component.sha256.range(of: #"\A[0-9A-Fa-f]{64}\z"#, options: .regularExpression) != nil else {
                throw HighballError.failed("Component '\(name)' must have a 64-character hexadecimal SHA-256 checksum.")
            }
            guard component.size.map({ $0 >= 0 }) ?? true else {
                throw HighballError.failed("Component '\(name)' size must not be negative.")
            }
            if let extract = component.extract {
                let paths = [extract.into, extract.subpath, extract.strip].compactMap { $0 }
                guard paths.allSatisfy(Self.isManifestPath) else {
                    throw HighballError.failed("Component extraction paths must be relative and stay inside the engine folder.")
                }
            }
        }
    }

    private static func isManifestName(_ name: String) -> Bool {
        name.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil
    }

    private static func isManifestPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.utf8.contains(0) && !path.split(separator: "/").contains("..")
    }

    private static func isComponentURL(_ url: URL) -> Bool {
        if url.isFileURL {
            return url.path.hasPrefix("/") && [nil, "", "localhost"].contains(url.host?.lowercased())
        }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }
}
