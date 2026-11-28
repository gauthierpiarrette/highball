import Foundation

/// Both UI entry points load the same manifest format before handing it to EngineStore.
public enum CustomEngineImport {
    public static func manifestURL(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    public static func load(from source: URL, reservedIDs: Set<String> = [], session: URLSession? = nil) async throws -> EngineManifest {
        try Task.checkCancellation()
        let data: Data
        if source.isFileURL {
            data = try Data(contentsOf: source)
        } else {
            guard manifestURL(from: source.absoluteString) != nil else {
                throw HighballError.failed("Enter a valid HTTP or HTTPS URL for the engine manifest JSON.")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            let downloadSession = session ?? URLSession(configuration: configuration)
            defer { if session == nil { downloadSession.finishTasksAndInvalidate() } }
            var request = URLRequest(url: source)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (body, response) = try await downloadSession.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw HighballError.failed("The engine manifest URL did not return a successful response. Check the URL and try again.")
            }
            data = body
        }
        try Task.checkCancellation()
        let manifest: EngineManifest
        do { manifest = try JSONDecoder().decode(EngineManifest.self, from: data) }
        catch is DecodingError {
            throw HighballError.failed("This JSON is not a valid engine manifest. Use Highball's engine manifest format.")
        }
        try manifest.validateForCustomImport(reservedIDs: reservedIDs)
        return manifest
    }
}

extension EngineManifest {
    /// Importing a custom manifest uses the CLI format, but must describe a complete engine
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
