import XCTest
@testable import HighballKit

final class SteamFirstStartTests: XCTestCase {
    func testHungOnlyAfterPatienceWithNoConnectionAndNoLogin() {
        let done = Date(timeIntervalSince1970: 1_000)
        let now = done.addingTimeInterval(SteamFirstStart.patience + 1)
        XCTAssertTrue(SteamFirstStart.isHung(bootstrapDone: done, lastConnection: nil, everLoggedIn: false, now: now))
        XCTAssertFalse(SteamFirstStart.isHung(bootstrapDone: done, lastConnection: nil, everLoggedIn: false, now: done.addingTimeInterval(30)), "give it time")
        XCTAssertFalse(SteamFirstStart.isHung(bootstrapDone: done, lastConnection: done.addingTimeInterval(20), everLoggedIn: false, now: now), "it connected: alive")
        XCTAssertTrue(SteamFirstStart.isHung(bootstrapDone: done, lastConnection: done.addingTimeInterval(-500), everLoggedIn: false, now: now), "a connection older than the bootstrap does not count")
        XCTAssertFalse(SteamFirstStart.isHung(bootstrapDone: done, lastConnection: nil, everLoggedIn: true, now: now), "a client that has logged in before is never restarted by this")
        XCTAssertFalse(SteamFirstStart.isHung(bootstrapDone: nil, lastConnection: nil, everLoggedIn: false, now: now), "no bootstrap record: nothing to judge")
    }

    func testReadsSteamsOwnLogs() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "steam-\(UUID().uuidString)")
        let logs = root.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        let done = Date().addingTimeInterval(-600)
        try "[\(f.string(from: done.addingTimeInterval(-5)))] Verifying installation...\n[\(f.string(from: done))] Update complete, launching Steam...\n[\(f.string(from: done))] Shutdown\n"
            .write(to: logs.appending(path: "bootstrap_log.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SteamFirstStart.isHung(steamRoot: root), "bootstrap done 10 min ago, never connected, never logged in")
        try "[\(f.string(from: done.addingTimeInterval(40)))] [Connecting, 0, 7] [U:1:0] Connect() starting connection\n"
            .write(to: logs.appending(path: "connection_log.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(SteamFirstStart.isHung(steamRoot: root), "it connected after the bootstrap")
    }
}
