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

/// Presentation decoder over the same appdetails client used by native Mac detection.
public struct SteamGameDetailsStore: Sendable {
    public typealias Language = SteamAppDetailsClient.Language
    public static let shared = SteamGameDetailsStore(client: .shared)
    static let maxAge = SteamAppDetailsClient.maxAge
    private let client: SteamAppDetailsClient

    public init(client: SteamAppDetailsClient = .shared) { self.client = client }

    init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> (Data, Int)) {
        client = SteamAppDetailsClient(directory: directory, fetch: fetch)
    }

    public func details(appID: Int, language: Language = .english, now: Date = Date()) async -> SteamGameDetails? {
        guard let data = await client.appDetails(appID: appID, language: language, now: now) else { return nil }
        return SteamGameDetails.parse(data, appID: appID)
    }
}
