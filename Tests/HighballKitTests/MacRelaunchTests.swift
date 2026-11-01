import XCTest
@testable import HighballKit

/// Closing a Mac game opened outside Highball to start it again through Highball.
final class MacRelaunchTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func takesOver(gameRunning: Bool = false, startedAgo: TimeInterval? = nil, takenOverAgo: TimeInterval? = nil,
                           appLaunchedAgo: TimeInterval? = 2, appTerminated: Bool = false, busy: Bool = false,
                           canStart: Bool = true) -> Bool {
        MacRelaunch.shouldTakeOver(now: now, gameRunning: gameRunning,
                                   startedAt: startedAgo.map { now.addingTimeInterval(-$0) },
                                   takenOverAt: takenOverAgo.map { now.addingTimeInterval(-$0) },
                                   appLaunchedAt: appLaunchedAgo.map { now.addingTimeInterval(-$0) },
                                   appTerminated: appTerminated, busy: busy, canStart: canStart)
    }

    func testAFreshOutsideLaunchHighballCanStartIsTakenOver() {
        XCTAssertTrue(takesOver())
        XCTAssertTrue(takesOver(startedAgo: 20, takenOverAgo: 90))
    }

    /// A launcher's hand-over opens the game long after Highball started it: still its own.
    func testNothingIsClosedWhileTheGameHighballStartedRuns() {
        XCTAssertFalse(takesOver(gameRunning: true))
        XCTAssertFalse(takesOver(gameRunning: true, startedAgo: 600))
    }

    func testALaunchSoonAfterHighballStartedTheGameIsHighballsOwn() {
        XCTAssertFalse(takesOver(startedAgo: 3))
        XCTAssertFalse(takesOver(startedAgo: 14.9))
        XCTAssertTrue(takesOver(startedAgo: 15))
    }

    func testAGameClosedOnceIsNotClosedAgainWithinAMinute() {
        XCTAssertFalse(takesOver(takenOverAgo: 5))
        XCTAssertFalse(takesOver(takenOverAgo: 59))
        XCTAssertTrue(takesOver(takenOverAgo: 60))
    }

    func testOnlyAnAppStillRunningAndJustOpenedIsClosed() {
        XCTAssertFalse(takesOver(appTerminated: true))
        XCTAssertFalse(takesOver(appLaunchedAgo: nil))
        XCTAssertFalse(takesOver(appLaunchedAgo: 8))
        XCTAssertTrue(takesOver(appLaunchedAgo: 7.9))
    }

    /// Closing the game is only worth it when Highball starts it again at once.
    func testABusyHighballOrOneThatCannotStartTheGameLeavesItAlone() {
        XCTAssertFalse(takesOver(busy: true))
        XCTAssertFalse(takesOver(canStart: false))
    }

    func testAnAppIsFromAGamesFolderOnlyWhenItIsTheFolderOrInsideIt() {
        XCTAssertTrue(MacRelaunch.opens(bundle: "/Applications/Foo.app", from: "/Applications/Foo.app"))
        XCTAssertTrue(MacRelaunch.opens(bundle: "/Games/Garlic/Garlic.app", from: "/Games/Garlic"))
        XCTAssertFalse(MacRelaunch.opens(bundle: "/Applications/Foo Deluxe.app", from: "/Applications/Foo"))
        XCTAssertFalse(MacRelaunch.opens(bundle: "/Games/Garlic2/Garlic.app", from: "/Games/Garlic"))
    }
}
