import XCTest
@testable import HighballKit

final class PlayLinkTests: XCTestCase {
    func testPlayLinksStillParseAndRoundTrip() {
        let steam = PlayLink.parse(URL(string: "highball://play/steam/620?t=abc")!)
        XCTAssertEqual(steam, PlayLink.Request(target: .steam(appid: 620), token: "abc"))
        XCTAssertEqual(PlayLink.url(for: .steam(appid: 620), token: "abc").absoluteString, "highball://play/steam/620?t=abc")
        XCTAssertNil(PlayLink.parse(URL(string: "highball://play/steam/0")!))
    }

    /// Issue #53: a Mac app for a launcher opens it through `highball://open/launcher/<id>`.
    func testLauncherLinkParsesAndRoundTrips() {
        let url = PlayLink.url(for: .launcher(id: "steam"), token: "tok")
        XCTAssertEqual(url.absoluteString, "highball://open/launcher/steam?t=tok")
        XCTAssertEqual(PlayLink.parse(url), PlayLink.Request(target: .launcher(id: "steam"), token: "tok"))
        XCTAssertEqual(PlayLink.Target.launcher(id: "epic").libraryID, "launcher:epic")
        XCTAssertNil(PlayLink.parse(URL(string: "highball://open/steam")!))
        XCTAssertNil(PlayLink.parse(URL(string: "highball://open/launcher/../x")!))
        XCTAssertNil(PlayLink.parse(URL(string: "highball://open/launcher/Steam%20Client")!))
    }

    /// A stub must not drag Highball in front of the game it starts (issue #53).
    func testStubOpensTheLinkInTheBackground() {
        let script = MacAppStub.launchScript(url: URL(string: "highball://play/steam/620?t=x")!)
        XCTAssertTrue(script.contains("/usr/bin/open -g \"highball://play/steam/620?t=x\""))
    }
}
