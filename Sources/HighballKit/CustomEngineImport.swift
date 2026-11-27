import Foundation

extension EngineManifest {
    /// Importing a local manifest uses the CLI format, but must describe a complete engine
    /// with its own ID. In particular, it must not shadow a manifest shipped by the app.
    public func validateForCustomImport(reservedIDs: Set<String> = []) throws {
        guard Self.isImportName(id) else {
            throw HighballError.failed("The engine ID must start with a letter or number and contain only letters, numbers, periods, underscores or hyphens.")
        }
        guard !reservedIDs.contains(id) else {
            throw HighballError.failed("This engine ID is reserved by Highball. Give each custom build a unique ID.")
        }
        guard components["wine"] != nil else {
            throw HighballError.failed("This manifest does not describe a complete engine. It must include a Wine component.")
        }
        guard arch == "x86_64" || arch == "arm64" else {
            throw HighballError.failed("This engine architecture is not supported. Use x86_64 or arm64.")
        }
        for (name, component) in components {
            guard Self.isImportName(name) else {
                throw HighballError.failed("The manifest contains an invalid component name.")
            }
            if let extract = component.extract {
                let paths = [extract.into, extract.subpath, extract.strip].compactMap { $0 }
                guard paths.allSatisfy(Self.isImportPath) else {
                    throw HighballError.failed("Component extraction paths must be relative and stay inside the engine folder.")
                }
            }
        }
    }

    private static func isImportName(_ name: String) -> Bool {
        name.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil
            && !name.utf8.contains(0)
    }

    private static func isImportPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.utf8.contains(0) && !path.split(separator: "/").contains("..")
    }
}
