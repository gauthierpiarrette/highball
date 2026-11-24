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
        XCTAssertTrue(script.contains("/usr/bin/open -g 'highball://play/steam/620?t=x'"))
    }

    /// sh hands the stub's link to open exactly as Highball wrote it: an environment's name may
    /// hold `$` and `'`, which a play link keeps unescaped.
    func testStubPassesTheLinkVerbatim() throws {
        let target = PlayLink.Target.pin(bottle: "Cash$$ $(echo x) Tom's", id: UUID())
        let url = PlayLink.url(for: target, token: "tok")
        let script = MacAppStub.launchScript(url: url).replacingOccurrences(of: "exec /usr/bin/open -g ", with: "printf %s ")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), url.absoluteString)
        XCTAssertEqual(PlayLink.parse(url)?.target, target)
    }

    /// A title is text in the stub's Info.plist: "Mount & Blade II" made a plist macOS rejects.
    func testStubInfoPlistReadsWithMarkupInTheTitle() throws {
        let name = MacAppStub.appName(for: "Mount & Blade <II> \"Bannerlord\"")
        let data = Data(MacAppStub.infoPlist(appName: name, bundleID: "app.highball.stub.x").utf8)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleName"] as? String, name)
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, name)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "launch")
    }
}
