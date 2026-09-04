import Foundation

/// The install funnel, recorded locally and never sent on its own (UX plan 0.7). Each event is
/// one line in `logs/funnel.jsonl`. Sending is a separate, explicit act: the app builds an
/// aggregate the person reads first, and it travels as a public issue, the way reports do.
public enum FunnelLog {
    public enum Event: String, Codable, CaseIterable, Sendable {
        case installStarted = "install-started"
        case downloadFailed = "download-failed"
        case extractFailed = "extract-failed"
        case installCompleted = "install-completed"
        case environmentCreated = "environment-created"
        case firstLaunch = "first-launch"
        case firstGameProcess = "first-game-process"
        case sessionEnded = "session-ended"
    }

    public struct Record: Codable, Sendable, Equatable {
        public var event: Event
        public var at: Date
        /// A detail with no personal data: a URLError code, a byte offset, a duration in seconds.
        public var detail: String?
        public init(event: Event, at: Date = Date(), detail: String? = nil) { self.event = event; self.at = at; self.detail = detail }
    }

    public static func file(in logs: URL) -> URL { logs.appending(path: "funnel.jsonl") }

    public static func append(_ record: Record, to logs: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let url = file(in: logs)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd(); handle.write(data); handle.write(Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    public static func records(in logs: URL) -> [Record] {
        guard let text = try? String(contentsOf: file(in: logs), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(Record.self, from: Data($0.utf8)) }
    }

    /// Counts per event plus the failure details, in words a person can check before sending.
    /// Pure: the same records always give the same text.
    public static func aggregate(_ records: [Record], appVersion: String, macos: String, chip: String) -> String {
        var lines = ["Highball \(appVersion), macOS \(macos), \(chip)", ""]
        for event in Event.allCases {
            let matching = records.filter { $0.event == event }
            guard !matching.isEmpty else { continue }
            var line = "\(event.rawValue): \(matching.count)"
            let details = matching.compactMap(\.detail)
            if !details.isEmpty, event == .downloadFailed || event == .extractFailed {
                line += " (" + details.joined(separator: "; ") + ")"
            }
            lines.append(line)
        }
        if lines.count == 2 { lines.append("no events yet") }
        return lines.joined(separator: "\n")
    }

    /// The issue that carries the aggregate: the person sees the text before the browser opens.
    public static func url(aggregate: String) -> URL {
        var comps = URLComponents(string: "https://github.com/gauthierpiarrette/highball/issues/new")!
        comps.queryItems = [URLQueryItem(name: "title", value: "Install statistics"),
                            URLQueryItem(name: "labels", value: "funnel"),
                            URLQueryItem(name: "body", value: aggregate)]
        return comps.url!
    }
}
