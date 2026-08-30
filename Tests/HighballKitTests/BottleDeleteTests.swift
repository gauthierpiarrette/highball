import XCTest
@testable import HighballKit

/// Issue #38: deleting a bottle reported "you don't have permission to access it" and left the
/// bottle half-destroyed — invisible to `list()`, refused by `delete()` and blocked by
/// `create()`'s name check, with its files still on disk.
///
/// Every test here asserts `assertFullyGone`, not just that `bottles/<name>` disappeared. The
/// first version of this suite checked only the latter, which `rename(2)` alone guarantees — so
/// a purge that deleted nothing at all kept 12 of 13 tests green. Checking `.trash` is what makes
/// these tests able to fail.
final class BottleDeleteTests: XCTestCase {
    private var home: URL!
    private var paths: HighballPaths!
    private var store: BottleStore!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "hb-del-\(UUID().uuidString)")
        paths = HighballPaths(home: home)
        store = BottleStore(paths: paths)
        try paths.ensure()
    }

    override func tearDownWithError() throws {
        guard let home else { return }
        // Deliberately not Purge.tree: cleaning up with the code under test would let a broken
        // purge tidy away its own evidence.
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "-N", home.path]).waitUntilExit()
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/chflags"), arguments: ["-R", "nouchg", home.path]).waitUntilExit()
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+rwX", home.path]).waitUntilExit()
        _ = try? Process.run(URL(fileURLWithPath: "/bin/rm"), arguments: ["-rf", home.path]).waitUntilExit()
    }

    // MARK: Helpers

    /// The assertion that matters: the bottle is gone from `bottles/` AND the purge finished, so
    /// nothing is parked in `.trash` and no leftovers were reported.
    private func assertFullyGone(_ name: String, _ leftovers: [PurgeFailure],
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottle(name).path),
                       "bottles/\(name) still exists", file: file, line: line)
        XCTAssertEqual(leftovers.map(\.description), [], "delete reported leftovers", file: file, line: line)
        let trash = (try? FileManager.default.contentsOfDirectory(atPath: paths.trash.path)) ?? []
        XCTAssertEqual(trash, [], "the purge left the tree in .trash", file: file, line: line)
    }

    @discardableResult
    private func makeBottle(_ name: String, files: Int = 30) throws -> URL {
        let url = paths.bottle(name)
        let system32 = url.appending(path: "drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appending(path: "dosdevices"), withIntermediateDirectories: true)
        for i in 0..<files {
            try "MZ".write(to: system32.appending(path: "lib\(i).dll"), atomically: true, encoding: .utf8)
        }
        for meta in ["system.reg", "user.reg", "userdef.reg", ".update-timestamp"] {
            try "x".write(to: url.appending(path: meta), atomically: true, encoding: .utf8)
        }
        try Bottle(url: url, settings: BottleSettings(name: name, engineID: "test-engine")).save()
        return url
    }

    /// A directory macOS will not let us empty — what broke #38.
    private func lock(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "locked".write(to: url.appending(path: "inside.dat"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }

    // MARK: The bug

    func testDeleteSucceedsWithAnUnwritableSubdirectory() throws {
        let url = try makeBottle("play")
        let locked = url.appending(path: "drive_c/Program Files/Game/data")
        try lock(locked)
        // Naming the file proves the purge descended, not merely that the bottle was renamed.
        let inside = locked.appending(path: "inside.dat").path

        try assertFullyGone("play", try store.delete("play"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside), "the unwritable directory's contents survived")
    }

    func testDeleteSucceedsWithImmutableAndUnreadableEntries() throws {
        let url = try makeBottle("play")
        let dir = url.appending(path: "drive_c/Program Files/Game")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let immutable = dir.appending(path: "locked.dat")
        try "x".write(to: immutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: immutable.path)
        let unreadable = dir.appending(path: "unreadable")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try "x".write(to: unreadable.appending(path: "f"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        try assertFullyGone("play", try store.delete("play"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: immutable.path), "the immutable file survived")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadable.path), "the unreadable directory survived")
    }

    func testDeleteSucceedsWithADenyDeleteACL() throws {
        let url = try makeBottle("play")
        let dir = url.appending(path: "drive_c/Program Files/Game")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let guarded = dir.appending(path: "guarded.dat")
        try "x".write(to: guarded, atomically: true, encoding: .utf8)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone deny delete", guarded.path]
        try chmod.run(); chmod.waitUntilExit()

        try assertFullyGone("play", try store.delete("play"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: guarded.path), "the ACL-protected file survived")
    }

    /// The name must be reusable the instant delete returns; #38's reporter could not recreate his.
    func testDeleteFreesTheNameForReuse() throws {
        let url = try makeBottle("play")
        try lock(url.appending(path: "drive_c/Program Files/Game/data"))
        _ = try store.delete("play")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottle("play").path))
        XCTAssertNoThrow(try makeBottle("play"), "the name must be reusable")
    }

    // MARK: Safety

    /// The mistake that would be catastrophic. Every bottle links
    /// drive_c/users/<user>/{Documents,Desktop,Downloads} at the real home folders and
    /// dosdevices/z: at /, so a purge that resolved paths instead of holding descriptors would
    /// delete the user's data — a path-based version did exactly that under a concurrent swap.
    func testPurgeNeverFollowsSymlinksOutOfTheTree() throws {
        let url = try makeBottle("play")
        let outside = home.appending(path: "precious")
        try FileManager.default.createDirectory(at: outside.appending(path: "sub"), withIntermediateDirectories: true)
        let canary = outside.appending(path: "sub/canary.txt")
        try "do not delete".write(to: canary, atomically: true, encoding: .utf8)

        let users = url.appending(path: "drive_c/users/tester")
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: users.appending(path: "Documents"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: url.appending(path: "dosdevices/z:"),
                                                   withDestinationURL: URL(fileURLWithPath: "/"))
        // Force the slow path so the hand-written walk is what runs.
        try lock(url.appending(path: "drive_c/Program Files/Game/data"))

        try assertFullyGone("play", try store.delete("play"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canary.path), "the purge followed a symlink out of the bottle")
        XCTAssertEqual(try String(contentsOf: canary, encoding: .utf8), "do not delete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/usr"), "/ must be untouched")
    }

    /// `chmod -R -N` follows symlinks (and macOS refuses `-R -h` together), so the ACL-clearing
    /// step used to reach through a bottle's Documents link and strip the ACL off the real folder.
    func testPurgeLeavesACLsOnSymlinkTargetsOutsideTheTree() throws {
        let url = try makeBottle("play")
        let outside = home.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone deny delete", outside.path]
        try chmod.run(); chmod.waitUntilExit()

        let users = url.appending(path: "drive_c/users/tester")
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: users.appending(path: "Documents"), withDestinationURL: outside)
        try lock(url.appending(path: "drive_c/Program Files/Game/data"))

        try assertFullyGone("play", try store.delete("play"))
        let ls = Process(), pipe = Pipe()
        ls.executableURL = URL(fileURLWithPath: "/bin/ls")
        ls.arguments = ["-lde", outside.path]
        ls.standardOutput = pipe
        try ls.run(); ls.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("deny delete"), "the purge stripped an ACL outside the bottle:\n\(out)")
    }

    /// A destructive call must not take a name that resolves anywhere but inside bottles/.
    /// Dropping the old bottle.json guard removed this protection by accident, and
    /// `bottle delete ../../Something` then purged that directory.
    func testDeleteRefusesNamesThatEscapeTheBottlesFolder() throws {
        let outside = home.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let canary = outside.appending(path: "canary.txt")
        try "keep".write(to: canary, atomically: true, encoding: .utf8)

        for bad in ["..", ".", "", "../outside", "../../etc", "a/b", "bottles/../../outside"] {
            XCTAssertThrowsError(try store.delete(bad), "'\(bad)' must be refused")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: canary.path), "an escaping name reached outside bottles/")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    /// A prefix deeper than a thread's stack must not wedge the app. A recursive walk overflowed
    /// the 512 KB stack of a cooperative-pool thread at ~450 levels and hung in an uninterruptible
    /// wait; the iterative walk has no depth ceiling.
    func testDeleteHandlesATreeDeeperThanTheStack() throws {
        let url = try makeBottle("play")
        let fm = FileManager.default
        let start = fm.currentDirectoryPath
        defer { fm.changeCurrentDirectoryPath(start) }
        let deep = url.appending(path: "drive_c/deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        // chdir-relative, because an absolute path over PATH_MAX cannot even be created.
        XCTAssertTrue(fm.changeCurrentDirectoryPath(deep.path))
        let segment = String(repeating: "d", count: 31)
        for _ in 0..<700 {
            guard (try? fm.createDirectory(atPath: segment, withIntermediateDirectories: false)) != nil,
                  fm.changeCurrentDirectoryPath(segment) else { break }
        }
        fm.createFile(atPath: "leaf.txt", contents: Data("x".utf8))
        fm.changeCurrentDirectoryPath(start)

        try assertFullyGone("play", try store.delete("play"))
    }

    /// The walk holds one descriptor per level, so its ceiling is RLIMIT_NOFILE, not the stack —
    /// and the shipping app is not the shell. A GUI-launched .app starts with a soft limit of 256
    /// while a login shell has over a million, so a deep prefix purged fine in testing and
    /// stranded itself permanently for a real user, blaming "Directory not empty".
    func testDeleteHandlesADeepTreeUnderTheAppsFileLimit() throws {
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)
        defer { var restore = original; _ = setrlimit(RLIMIT_NOFILE, &restore) }
        var tight = original
        tight.rlim_cur = 256
        try XCTSkipUnless(setrlimit(RLIMIT_NOFILE, &tight) == 0, "cannot lower RLIMIT_NOFILE here")

        let url = try makeBottle("play")
        let fm = FileManager.default
        let start = fm.currentDirectoryPath
        defer { fm.changeCurrentDirectoryPath(start) }
        let deep = url.appending(path: "drive_c/deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        XCTAssertTrue(fm.changeCurrentDirectoryPath(deep.path))
        let segment = String(repeating: "d", count: 20)
        for _ in 0..<500 {
            guard (try? fm.createDirectory(atPath: segment, withIntermediateDirectories: false)) != nil,
                  fm.changeCurrentDirectoryPath(segment) else { break }
        }
        fm.createFile(atPath: "leaf.txt", contents: Data("x".utf8))
        fm.changeCurrentDirectoryPath(start)

        try assertFullyGone("play", try store.delete("play"))
    }

    func testPurgeRefusesShallowPaths() {
        for dangerous in ["/", "/Users", "/Users/someone", "/Volumes"] {
            let failures = Purge.tree(at: URL(fileURLWithPath: dangerous))
            XCTAssertEqual(failures.first?.code, EINVAL, "\(dangerous) must be refused")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/Users"))
    }

    /// Guards against someone replacing rename(2) with a copy-then-delete implementation, which
    /// across volumes is exactly what reintroduces #38. Tests the move on its own, because after
    /// the purge there is nothing left to compare and a copy would look identical from outside.
    func testDeleteMovesTheTreeWithoutCopyingIt() throws {
        let url = try makeBottle("play")
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)

        let moved = try store.moveToTrash(url, name: "play")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the source must be gone at once")
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: moved.path)[.systemFileNumber] as? Int)
        XCTAssertEqual(before, after, "the tree was copied, not renamed")
        // A copy would also duplicate the contents; the rename moves the whole subtree intact.
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appending(path: "drive_c/windows/system32/lib0.dll").path))
    }

    // MARK: Recovery

    func testADamagedBottleIsListedAndDeletable() throws {
        let url = try makeBottle("play")
        try FileManager.default.removeItem(at: url.appending(path: "bottle.json"))

        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertEqual(try store.damaged().map(\.name), ["play"])
        try assertFullyGone("play", try store.delete("play"))
    }

    func testALegacyGinBottleIsDeletable() throws {
        let url = try makeBottle("play")
        try FileManager.default.moveItem(at: url.appending(path: "bottle.json"),
                                         to: url.appending(path: "gin.json"))
        XCTAssertEqual(try store.list().map(\.name), ["play"])
        XCTAssertTrue(try store.damaged().isEmpty, "a loadable bottle must never also be damaged")
        try assertFullyGone("play", try store.delete("play"))
    }

    func testDeletingAnAbsentBottleReportsItMissing() {
        XCTAssertThrowsError(try store.delete("nope"))
    }

    /// Anything occupying a name in bottles/ blocks create(), so it must be reachable. Only
    /// dot-files are hidden; a stray file or dangling symlink is reported so it can be removed.
    func testDamagedSurfacesAnythingOccupyingABottleName() throws {
        try "x".write(to: paths.bottles.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)
        try "x".write(to: paths.bottles.appending(path: "loose.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: paths.bottles.appending(path: "Unplugged").path,
                                                   withDestinationPath: "/nonexistent-target")
        try makeBottle("play")

        XCTAssertEqual(try store.list().map(\.name), ["play"])
        XCTAssertEqual(try store.damaged().map(\.name), ["Unplugged", "loose.txt"],
                       "a dot-file stays hidden; anything else taking a name must be visible")
        // And each must be removable, or surfacing it would be pointless.
        for name in ["Unplugged", "loose.txt"] { XCTAssertNoThrow(try store.delete(name)) }
        XCTAssertTrue(try store.damaged().isEmpty)
    }

    /// A dangling symlink used to slip past create()'s fileExists guard, which follows links, so
    /// creation failed later with a raw Foundation error on a name nothing would show.
    func testCreateRefusesANameHeldByADanglingSymlink() throws {
        try FileManager.default.createSymbolicLink(atPath: paths.bottle("Unplugged").path,
                                                   withDestinationPath: "/nonexistent-target")
        XCTAssertEqual(try store.damaged().map(\.name), ["Unplugged"])
        var st = stat()
        XCTAssertEqual(lstat(paths.bottle("Unplugged").path, &st), 0, "lstat must see the link")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottle("Unplugged").path),
                       "fileExists follows the link, which is why the guard had to change")
    }

    func testSweepTrashClearsWhatAnEarlierPurgeLeft() throws {
        let stale = paths.trash.appending(path: "play-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale.appending(path: "drive_c"), withIntermediateDirectories: true)
        try "x".write(to: stale.appending(path: "drive_c/f"), atomically: true, encoding: .utf8)

        XCTAssertTrue(store.sweepTrash().isEmpty, "a purgeable leftover must not be reported as a failure")
        let trash = (try? FileManager.default.contentsOfDirectory(atPath: paths.trash.path)) ?? []
        XCTAssertEqual(trash, [], "sweepTrash left the tree behind")
    }

    func testTrashNameCannotEscapeTheTrashDirectory() {
        XCTAssertFalse(BottleStore.trashName("../../etc").contains("/"))
        XCTAssertFalse(BottleStore.trashName("..").contains("."))
        XCTAssertFalse(BottleStore.trashName("a/b:c").contains("/"))
    }
}
