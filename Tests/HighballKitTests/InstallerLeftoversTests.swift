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

    func testProcessesThatEndedDuringTheInstallAreNotReported() {
        XCTAssertEqual(RecipeRunner.installerLeftovers(before: [10, 11, 12], after: [10, 99], wasIdle: true), [99])
    }
}
