import Foundation

/// Presentation data from the Steam store. This never changes compatibility or launch settings.
public struct SteamGameDetails: Codable, Sendable, Equatable {
    public struct Screenshot: Codable, Sendable, Equatable {
        public let thumbnail: URL
        public let full: URL
    }

    public let appID: Int
    public let summary: String
    public let description: String
    public let header: URL?
    public let screenshots: [Screenshot]
    public let developers: [String]
    public let publishers: [String]
    public let genres: [String]
    public let releaseDate: String?

    public var storeURL: URL { URL(string: "https://store.steampowered.com/app/\(appID)/")! }

    /// Delisted games, malformed replies and replies for another app are unavailable, not empty games.
    static func parse(_ data: Data, appID: Int) -> Self? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = response[String(appID)] as? [String: Any], app["success"] as? Bool == true,
              let fields = app["data"] as? [String: Any], fields["steam_appid"] as? Int == appID else { return nil }
        let screenshots = (fields["screenshots"] as? [[String: Any]] ?? []).compactMap { screenshot -> Screenshot? in
            guard let thumbnail = imageURL(screenshot["path_thumbnail"] as? String),
                  let full = imageURL(screenshot["path_full"] as? String) else { return nil }
            return Screenshot(thumbnail: thumbnail, full: full)
        }
        var seen = Set<URL>()
        let release = fields["release_date"] as? [String: Any]
        let date = (release?["date"] as? String).map(plainText)
        return Self(appID: appID,
                    summary: plainText(fields["short_description"] as? String ?? ""),
                    description: plainText(fields["about_the_game"] as? String ?? ""),
                    header: imageURL(fields["header_image"] as? String),
                    screenshots: Array(screenshots.filter { seen.insert($0.full).inserted }.prefix(20)),
                    developers: (fields["developers"] as? [String] ?? []).map(plainText),
                    publishers: (fields["publishers"] as? [String] ?? []).map(plainText),
                    genres: (fields["genres"] as? [[String: Any]] ?? []).compactMap { ($0["description"] as? String).map(plainText) },
                    releaseDate: date?.isEmpty == false ? date : nil)
    }

    private static func imageURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", let host = url.host,
              host == "steamstatic.com" || host.hasSuffix(".steamstatic.com") ||
                host == "steamusercontent.com" || host.hasSuffix(".steamusercontent.com") else { return nil }
        return url
    }

    /// Render store copy as text, without a web view or HTML's remote image/script loading.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|h[1-6]|ul|ol)\\s*>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<li\\b[^>]*>", with: "\n• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let entities = ["nbsp": " ", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "amp": "&",
                        "ndash": "–", "mdash": "—", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "hellip": "…", "trade": "™", "reg": "®", "copy": "©"]
        if let regex = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), let keyRange = Range(match.range(at: 1), in: text) else { continue }
                let key = String(text[keyRange])
                let number = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : key.hasPrefix("#") ? UInt32(key.dropFirst()) : nil
                let value = number.flatMap(UnicodeScalar.init).map(String.init) ?? entities[key]
                if let value { text.replaceSubrange(range, with: value) }
            }
        }
        return text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One request when a page is opened, cached for a week. A failed refresh retains the old copy;
/// failures are backed off for five minutes and overlapping requests share one task.
public actor SteamGameDetailsStore {
    public enum Language: String, Sendable { case english, french }
    public static let shared = SteamGameDetailsStore()
    static let maxAge: TimeInterval = 7 * 24 * 3600
    private struct Record: Codable { let version: Int; let checked: Date; let details: SteamGameDetails }
    private let directory: URL
    private let fetch: @Sendable (URL) async throws -> (Data, Int)
    private var pending: [String: Task<SteamGameDetails?, Never>] = [:]
    private var failed: [String: Date] = [:]

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Highball/SteamDetails", directoryHint: .isDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        fetch = { url in
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> (Data, Int)) {
        self.directory = directory; self.fetch = fetch
    }

    public func details(appID: Int, language: Language = .english, now: Date = Date()) async -> SteamGameDetails? {
        guard appID > 0 else { return nil }
        let key = "\(appID)-\(language.rawValue)"
        let file = directory.appending(path: "\(key).json")
        let record = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        let cached = record?.version == 1 && record?.details.appID == appID ? record : nil
        if let cached, now.timeIntervalSince(cached.checked) < Self.maxAge { return cached.details }
        if let failure = failed[key], now.timeIntervalSince(failure) < 300 { return cached?.details }
        if let task = pending[key] { return await task.value ?? cached?.details }
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=\(language.rawValue)")!
        let fetch = self.fetch
        let task = Task<SteamGameDetails?, Never> {
            guard let (data, status) = try? await fetch(url), status == 200, data.count <= 2_000_000 else { return nil }
            return SteamGameDetails.parse(data, appID: appID)
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result {
            failed[key] = nil
            if let data = try? JSONEncoder().encode(Record(version: 1, checked: now, details: result)) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            return result
        }
        failed[key] = now
        return cached?.details
    }
}
