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
    func testShortcutsUseChosenFolderWithoutReplacingAnotherApp() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "shortcuts-\(UUID().uuidString)", directoryHint: .isDirectory)
        let other = folder.appending(path: "Portal & Co.app", directoryHint: .isDirectory)
        let marker = other.appending(path: "original")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        try Data("original".utf8).write(to: marker)
        let link = PlayLink.url(for: .steam(appid: 620), token: "local")
        let application = URL(fileURLWithPath: "/Applications/Player's Games/Highball.app")
        let app = try MacAppStub.write(title: "Portal & Co", libraryID: "steam:620", url: link, cover: nil,
                                       in: folder, application: application)
        XCTAssertEqual(app.lastPathComponent, "Portal & Co 2.app")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "original")
        XCTAssertEqual(MacAppStub.existing(libraryID: "steam:620", in: folder)?.resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path)
        let script = try String(contentsOf: app.appending(path: "Contents/MacOS/launch"), encoding: .utf8)
        XCTAssertTrue(script.contains(#"-a '/Applications/Player'\''s Games/Highball.app'"#))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")))
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Portal & Co")

        let updated = try MacAppStub.write(title: "Renamed", libraryID: "steam:620", url: link, cover: nil, in: folder)
        XCTAssertEqual(updated.resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path, "same target uses its existing shortcut")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "original")
        try Shell.run("/usr/bin/codesign", ["--verify", "--strict", updated.path])
    }

    func testLegacyShortcutRequiresExactTargetEvenWhenBundleIDsCollide() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "legacy-shortcuts-\(UUID().uuidString)", directoryHint: .isDirectory)
        let contents = folder.appending(path: "Same Name.app/Contents")
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let first = PlayLink.Target.epic(appName: "a-b")
        let second = PlayLink.Target.epic(appName: "a_b")
        XCTAssertEqual(MacAppStub.bundleID(for: first.libraryID), MacAppStub.bundleID(for: second.libraryID))
        try MacAppStub.infoPlist(appName: "Same Name", bundleID: MacAppStub.bundleID(for: first.libraryID))
            .write(to: contents.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        let url = PlayLink.url(for: first, token: "local")
        try "#!/bin/sh\nexec /usr/bin/open -g \"\(url.absoluteString)\"\n"
            .write(to: contents.appending(path: "MacOS/launch"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(MacAppStub.existing(libraryID: first.libraryID, in: folder))
        XCTAssertNil(MacAppStub.existing(libraryID: second.libraryID, in: folder))
    }
}
