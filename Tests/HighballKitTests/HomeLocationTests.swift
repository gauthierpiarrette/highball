import XCTest
@testable import HighballKit

/// A chosen data location (#24, #68): the resolver's precedence, the preflight on a folder, the
/// pointer file, and the mover that copies and checks before it removes anything.
final class HomeLocationTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "hb-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testPrecedenceExplicitThenEnvThenChosenThenDefault() {
        let d = URL(fileURLWithPath: "/d"), e = URL(fileURLWithPath: "/e"), c = URL(fileURLWithPath: "/c"), x = URL(fileURLWithPath: "/x")
        XCTAssertEqual(HighballPaths.resolve(explicit: x, env: e, configured: c, reachable: true, defaultHome: d).home, x)
        XCTAssertEqual(HighballPaths.resolve(explicit: nil, env: e, configured: c, reachable: true, defaultHome: d).home, e)
        XCTAssertEqual(HighballPaths.resolve(explicit: nil, env: nil, configured: c, reachable: true, defaultHome: d).home, c)
        let unplugged = HighballPaths.resolve(explicit: nil, env: nil, configured: c, reachable: false, defaultHome: d)
        XCTAssertEqual(unplugged.home, d, "an unplugged drive falls back to the default")
        XCTAssertEqual(unplugged.unavailable, c, "and says which location is missing")
        XCTAssertEqual(HighballPaths.resolve(explicit: nil, env: nil, configured: nil, reachable: false, defaultHome: d).home, d)
    }

    func testPointerFileRoundTrip() throws {
        let file = tmp.appending(path: "config.json")
        XCTAssertNil(HighballPaths.configuredHome(from: file))
        try HighballPaths.setConfiguredHome(URL(fileURLWithPath: "/Volumes/Games/Highball"), file: file)
        XCTAssertEqual(HighballPaths.configuredHome(from: file)?.path, "/Volumes/Games/Highball")
        try HighballPaths.setConfiguredHome(nil, file: file)
        XCTAssertNil(HighballPaths.configuredHome(from: file))
    }

    func testLocationPreflight() throws {
        let def = tmp.appending(path: "default"), good = tmp.appending(path: "good"), inside = def.appending(path: "inner")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        XCTAssertNil(HighballPaths.locationProblem(good, defaultHome: def))
        XCTAssertNotNil(HighballPaths.locationProblem(tmp.appending(path: "missing"), defaultHome: def))
        XCTAssertNotNil(HighballPaths.locationProblem(inside, defaultHome: def), "inside the default home would move the data into itself")
        XCTAssertNotNil(HighballPaths.locationProblem(tmp, defaultHome: tmp.appending(path: "default")), "the default's own parent is refused too")
    }

    // The volume check asks the volume instead of trusting a name. The old check read
    // volumeSupportsSymbolicLinks and refused exFAT by name, but macOS reports exFAT as supporting
    // symbolic links and creates them, so it never fired and the promised refusal never happened
    // (measured 2026-09-09: a home moved to exFAT was accepted and the bottle ran).
    // FAT32 caps a file at one byte under 4 GiB and game files pass that routinely, so a drive
    // that reports a small maximum is refused. Runs only where such a volume is mounted.
    func testSmallMaximumFileSizeIsRefused() throws {
        let fat = URL(fileURLWithPath: "/Volumes/FAT32TEST")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fat.path), "no FAT32 volume mounted")
        let problem = HighballPaths.locationProblem(fat, defaultHome: tmp)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("larger than") == true, "says why, not just no: \(problem ?? "nil")")
    }

    func testVolumeProbePassesOnAWritableFolderAndLeavesNothing() throws {
        let dir = tmp.appending(path: "vol")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(HighballPaths.volumeProblem(dir, uuid: "fixed-uuid"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
                       "the probe cleans up after itself, including the symlink and the executable")
    }

    func testVolumeProbeReportsAnUnwritableFolder() throws {
        let dir = tmp.appending(path: "ro")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertNotNil(HighballPaths.volumeProblem(dir), "a folder it cannot write in is refused")
    }

    func testMoveCopiesChecksThenRemovesAndKeepsLinks() throws {
        let src = tmp.appending(path: "src"), dst = tmp.appending(path: "dst")
        let fm = FileManager.default
        try fm.createDirectory(at: src.appending(path: "bottles/Games/dosdevices"), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appending(path: "engines/e/wine"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 5000).write(to: src.appending(path: "bottles/Games/system.reg"))
        try Data("x".utf8).write(to: src.appending(path: "engines/e/wine/w"))
        try Data("{}".utf8).write(to: src.appending(path: "library.json"))
        try Data("{\"home\":\"/x\"}".utf8).write(to: src.appending(path: "config.json"))
        try fm.createSymbolicLink(atPath: src.appending(path: "bottles/Games/dosdevices/c:").path, withDestinationPath: "../drive_c")
        let before = try HomeMove.tally(src.appending(path: "bottles"))
        var seen: [String] = []
        try HomeMove.move(from: src, to: dst) { seen.append($0) }
        XCTAssertEqual(seen, ["bottles", "engines", "library.json"], "the pointer file is not data")
        XCTAssertTrue(fm.fileExists(atPath: dst.appending(path: "bottles/Games/system.reg").path))
        let after = try HomeMove.tally(dst.appending(path: "bottles"))
        XCTAssertEqual(after.files, before.files); XCTAssertEqual(after.bytes, before.bytes)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dst.appending(path: "bottles/Games/dosdevices/c:").path), "../drive_c", "links travel as links")
        XCTAssertFalse(fm.fileExists(atPath: src.appending(path: "bottles").path), "removed at the source only after the check")
        XCTAssertTrue(fm.fileExists(atPath: src.appending(path: "config.json").path), "the pointer stays put")
    }

    func testHasData() throws {
        let p = HighballPaths(home: tmp)
        XCTAssertFalse(p.hasData)
        try FileManager.default.createDirectory(at: p.bottles.appending(path: "Games"), withIntermediateDirectories: true)
        XCTAssertTrue(p.hasData)
    }
}
