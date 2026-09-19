import XCTest
@testable import HighballKit

final class InstallerLeftoversTests: XCTestCase {
    func testNewProcessesAreLeftoversWhenTheEnvironmentWasIdle() {
        XCTAssertEqual(RecipeRunner.installerLeftovers(before: [10, 11], after: [10, 11, 42, 43], wasIdle: true), [42, 43])
    }

    func testNothingNewMeansNoLeftovers() {
        XCTAssertEqual(RecipeRunner.installerLeftovers(before: [10, 11], after: [10, 11], wasIdle: true), [])
    }

    func testABusyEnvironmentGetsNoCleanup() {
        // A running game's own new child (a launcher it spawned, a crash handler) is
        // indistinguishable from an installer leftover by pid alone, so nothing is ended.
        XCTAssertEqual(RecipeRunner.installerLeftovers(before: [10, 11], after: [10, 11, 42], wasIdle: false), [])
    }

    func testPlumbingThatAppearedIsNeverALeftover() {
        // A cold prefix boots its server and Windows services from the installer's own launch;
        // they are new pids but not the installer's, and ending them by signal broke the VC++
        // install on nightly-e2e (#160). The environment reset after the step handles them.
        XCTAssertEqual(RecipeRunner.installerLeftovers(before: [10], after: [10, 20, 21, 30], wasIdle: true,
                                                       isPlumbing: { $0 == 20 || $0 == 21 }), [30])
    }

    func testProcessesThatEndedDuringTheInstallAreNotReported() {
        XCTAssertEqual(RecipeRunner.installerLeftovers(before: [10, 11, 12], after: [10, 99], wasIdle: true), [99])
    }
}
