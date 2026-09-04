import XCTest
@testable import HighballKit

final class FunnelLogTests: XCTestCase {
    func testAppendAndReadBack() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "funnel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        FunnelLog.append(.init(event: .installStarted), to: dir)
        FunnelLog.append(.init(event: .downloadFailed, detail: "URLError -1005 at 164 MB"), to: dir)
        let records = FunnelLog.records(in: dir)
        XCTAssertEqual(records.map(\.event), [.installStarted, .downloadFailed])
        XCTAssertEqual(records[1].detail, "URLError -1005 at 164 MB")
    }

    func testAggregateIsCountsInWords() {
        let r: [FunnelLog.Record] = [
            .init(event: .installStarted), .init(event: .downloadFailed, detail: "URLError -1005 at 164 MB"),
            .init(event: .installStarted), .init(event: .installCompleted), .init(event: .sessionEnded, detail: "187 s"),
        ]
        let text = FunnelLog.aggregate(r, appVersion: "0.7.23", macos: "26.6.2", chip: "Apple M1 Pro")
        XCTAssertEqual(text, """
        Highball 0.7.23, macOS 26.6.2, Apple M1 Pro

        install-started: 2
        download-failed: 1 (URLError -1005 at 164 MB)
        install-completed: 1
        session-ended: 1
        """)
        XCTAssertTrue(FunnelLog.aggregate([], appVersion: "x", macos: "y", chip: "z").hasSuffix("no events yet"))
    }

    func testIssueURLCarriesTheAggregate() throws {
        let url = FunnelLog.url(aggregate: "install-started: 2")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["title"], "Install statistics")
        XCTAssertEqual(q["body"], "install-started: 2")
    }
}
