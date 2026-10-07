import Foundation

/// Shared store appdetails transport for native Mac flags and game-page information.
/// Full responses are cached once per language; only explicit unavailable-page replies persist
/// for a day. Transport errors can retry on the next open without discarding stale details.
public actor SteamAppDetailsClient {
    public enum Language: String, Sendable { case english, french }
    public static let shared = SteamAppDetailsClient()
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let failureAge: TimeInterval = 24 * 3600
    private struct Record: Codable {
        let version: Int
        let checked: Date
        let data: Data?
        let failed: Date?
    }
    private let directory: URL
    private let fetch: @Sendable (URL) async throws -> (Data, Int)
    private var pending: [String: Task<Data?, Never>] = [:]
    // One refusal stops both consumers, rather than continuing through the owned library.
    private var stoppedUntil: Date?

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Highball/SteamAppDetails", directoryHint: .isDirectory)
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

    public func appDetails(appID: Int, language: Language = .english, now: Date = Date()) async -> Data? {
        guard appID > 0 else { return nil }
        let key = "\(appID)-\(language.rawValue)"
        let file = directory.appending(path: "\(key).json")
        let record = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        let cached = record.flatMap { [1, 2].contains($0.version) ? $0 : nil }
        if let data = cached?.data, let checked = cached?.checked, now.timeIntervalSince(checked) < Self.maxAge { return data }
        // Version 1 also persisted transport failures; don't let those block an online retry.
        if cached?.version == 2, let failed = cached?.failed, now.timeIntervalSince(failed) < Self.failureAge { return cached?.data }
        if let stoppedUntil, now < stoppedUntil { return cached?.data }
        if let task = pending[key] { return await task.value }
        // The task includes cache writes and refusal handling before other callers resume.
        let task = Task { await self.load(appID: appID, language: language, file: file, cached: cached, now: now) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        return result
    }

    private func load(appID: Int, language: Language, file: URL, cached: Record?, now: Date) async -> Data? {
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=\(language.rawValue)")!
        let response = try? await fetch(url)
        if response?.1 == 429 || response?.1 == 403 { stoppedUntil = now.addingTimeInterval(Self.failureAge) }
        if let (data, status) = response, status == 200, data.count <= 2_000_000, Self.valid(data, appID: appID) {
            save(Record(version: 2, checked: now, data: data, failed: nil), to: file)
            return data
        }
        if let (data, status) = response, status == 200, data.count <= 2_000_000,
           Self.unavailable(data, appID: appID) {
            save(Record(version: 2, checked: cached?.checked ?? now, data: cached?.data, failed: now), to: file)
        }
        return cached?.data
    }

    private static func unavailable(_ data: Data, appID: Int) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = json[String(appID)] as? [String: Any] else { return false }
        return app["success"] as? Bool == false
    }

    private static func valid(_ data: Data, appID: Int) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = json[String(appID)] as? [String: Any], app["success"] as? Bool == true,
              let fields = app["data"] as? [String: Any], fields["steam_appid"] as? Int == appID else { return false }
        return true
    }

    private func save(_ record: Record, to file: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
