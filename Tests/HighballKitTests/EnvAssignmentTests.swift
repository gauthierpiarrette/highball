import XCTest
@testable import HighballKit

final class EnvAssignmentTests: XCTestCase {
    func testSetsAndKeepsEqualsInValue() {
        var env: [String: String] = [:]
        XCTAssertTrue(EnvAssignment.apply("WINEDLLPATH_PREPEND=/a:/b", to: &env))
        XCTAssertTrue(EnvAssignment.apply("X=a=b", to: &env))
        XCTAssertEqual(env, ["WINEDLLPATH_PREPEND": "/a:/b", "X": "a=b"])
    }

    func testEmptyValueRemovesTheKey() {
        var env = ["WINEDEBUG": "+loaddll", "KEEP": "1"]
        XCTAssertTrue(EnvAssignment.apply("WINEDEBUG=", to: &env))
        XCTAssertEqual(env, ["KEEP": "1"])
        XCTAssertTrue(EnvAssignment.apply("MISSING=", to: &env))
        XCTAssertEqual(env, ["KEEP": "1"])
    }

    func testRejectsTextWithoutKeyOrEquals() {
        var env: [String: String] = [:]
        XCTAssertFalse(EnvAssignment.apply("WINEDEBUG", to: &env))
        XCTAssertFalse(EnvAssignment.apply("=x", to: &env))
        XCTAssertTrue(env.isEmpty)
    }
}
