import XCTest
@testable import HighballKit

final class SteamGameActionTests: XCTestCase {
    /// Real lines from a bottle's console_log.txt, 2026-09-10 (Red Dead Redemption 2) and
    /// 2026-09-05 (a launch that went all the way through).
    private let eula = [
        #"[2026-09-10 02:42:04] GameAction [AppID 1174180, ActionID 1] : LaunchApp changed task to ShowEula with """#,
        #"[2026-09-10 02:42:04] GameAction [AppID 1174180, ActionID 1] : LaunchApp waiting for user response to ShowEula """#,
    ]
    private let completed = [
        #"[2026-09-05 06:08:57] GameAction [AppID 3240220, ActionID 2] : LaunchApp changed task to ShowInterstitials with """#,
        #"[2026-09-05 06:08:57] GameAction [AppID 3240220, ActionID 2] : LaunchApp waiting for user response to ShowInterstitials """#,
        #"[2026-09-05 06:08:57] GameAction [AppID 3240220, ActionID 2] : LaunchApp continues with user response "ShowInterstitials""#,
        #"[2026-09-05 06:08:57] GameAction [AppID 3240220, ActionID 2] : LaunchApp changed task to CreatingProcess with """#,
        #"[2026-09-05 06:08:57] GameAction [AppID 3240220, ActionID 2] : LaunchApp changed task to Completed with """#,
    ]

    private func at(_ s: String) -> Date { SteamGameAction.timestamp("[\(s)] x")! }

    func testParsesAppAndActionAndTask() {
        let line = SteamGameAction.parse(eula[1])
        XCTAssertEqual(line?.appID, 1174180)
        XCTAssertEqual(line?.actionID, 1)
        XCTAssertEqual(line?.step, .waiting("ShowEula"))
        XCTAssertEqual(SteamGameAction.parse(eula[0])?.step, .other)
    }

    func testStandingWaitIsReported() {
        let now = at("2026-09-10 02:43:00")
        let p = SteamGameAction.pending(lines: eula, now: now)
        XCTAssertEqual(p?.appID, 1174180)
        XCTAssertEqual(p?.task, "ShowEula")
        XCTAssertEqual(p?.actionID, 1)
    }

    func testFreshWaitIsGivenTimeToResolveItself() {
        // Steam answers several of these itself within the same second.
        let now = at("2026-09-10 02:42:05")
        XCTAssertNil(SteamGameAction.pending(lines: eula, now: now))
    }

    func testAnsweredWaitIsNotReported() {
        let now = at("2026-09-05 07:00:00")
        XCTAssertNil(SteamGameAction.pending(lines: completed, now: now),
                     "the launch went on past the wait")
    }

    func testNewerActionSupersedesAnEarlierWait() {
        let now = at("2026-09-05 07:00:00")
        XCTAssertNil(SteamGameAction.pending(lines: eula + completed, now: now),
                     "a later launch that completed is the current truth")
    }

    func testNonGameActionNoiseIsIgnored() {
        let noise = [
            "[2026-09-10 02:41:57] Client version: 1788652215",
            "[2026-09-10 02:41:57] SSGL: UI mode (0->7)",
            "",
        ]
        XCTAssertNil(SteamGameAction.pending(lines: noise, now: at("2026-09-10 03:00:00")))
        XCTAssertEqual(SteamGameAction.pending(lines: eula + noise, now: at("2026-09-10 03:00:00"))?.task,
                       "ShowEula",
                       "noise after the wait does not answer it")
    }

    func testMessageNamesTheLicenceForEula() {
        let p = SteamGameAction.Pending(appID: 1174180, task: "ShowEula", since: Date(), actionID: 1)
        XCTAssertEqual(SteamGameAction.message(for: p, name: "Red Dead Redemption 2"),
                       "Steam is waiting for you to accept the licence agreement for Red Dead Redemption 2. It is in the Steam window.")
        let other = SteamGameAction.Pending(appID: 1, task: "SomethingElse", since: Date(), actionID: 1)
        XCTAssertTrue(SteamGameAction.message(for: other, name: nil).contains("this game"))
    }
}
