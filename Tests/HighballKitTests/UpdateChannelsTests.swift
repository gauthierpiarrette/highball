import XCTest
@testable import HighballKit

/// The beta channel rule: off means the unnamed stable channel only, on adds exactly "beta".
/// A wrong answer either hides betas from testers or ships betas to everyone.
final class UpdateChannelsTests: XCTestCase {
    func testStableSeesNoNamedChannel() {
        XCTAssertEqual(UpdateChannels.allowed(beta: false), [])
    }

    func testBetaOptInSeesOnlyBeta() {
        XCTAssertEqual(UpdateChannels.allowed(beta: true), ["beta"])
        XCTAssertEqual(UpdateChannels.beta, "beta", "the name the release script writes into the appcast")
    }
}
