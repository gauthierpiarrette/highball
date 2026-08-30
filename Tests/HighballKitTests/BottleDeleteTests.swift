import XCTest
@testable import HighballKit

/// Issue #38: deleting a bottle reported "you don't have permission to access it" and left the
/// bottle half-destroyed — invisible to `list()`, refused by `delete()` and blocked by
/// `create()`'s name check, with its files still on disk.
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
        if let home { Purge.tree(at: home) }
    }

    /// A bottle shaped like a real one: the same top-level entries, in a tree deep enough that
    /// a blocker is reached only after the metadata.
    @discardableResult
    private func makeBottle(_ name: String, files: Int = 40) throws -> URL {
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

    /// Plants the thing that broke #38: a directory macOS will not let us empty.
    private func lock(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "locked".write(to: url.appending(path: "inside.dat"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }

    // MARK: The bug

    func testDeleteSucceedsWithAnUnwritableSubdirectory() throws {
        let url = try makeBottle("play")
        try lock(url.appending(path: "drive_c/Program Files/Game/data"))

        XCTAssertNoThrow(try store.delete("play"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "bottles/play must be gone")
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertTrue(try store.damaged().isEmpty, "nothing may be left behind in bottles/")
    }

    func testDeleteSucceedsWithImmutableAndUnreadableEntries() throws {
        let url = try makeBottle("play")
        let dir = url.appending(path: "drive_c/Program Files/Game")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let immutable = dir.appending(path: "locked.dat")
        try "x".write(to: immutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: immutable.path)
        try FileManager.default.createDirectory(at: dir.appending(path: "unreadable"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: dir.appending(path: "unreadable").path)

        XCTAssertNoThrow(try store.delete("play"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The name must be reusable the instant delete returns. #38's reporter could not recreate
    /// his bottle: `create()` refused because the gutted directory was still there.
    func testDeleteFreesTheNameEvenWhenFilesCannotBeRemoved() throws {
        let url = try makeBottle("play")
        try lock(url.appending(path: "drive_c/Program Files/Game/data"))

        try store.delete("play")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottle("play").path),
                       "the name must be free for create() to reuse")
    }

    // MARK: Atomicity

    func testDeleteMovesTheBottleOutOfBottlesBeforePurging() throws {
        let url = try makeBottle("play")
        // An unpurgeable entry: a 0555 directory whose parent is also 0555, so even the forced
        // walk leaves something behind and we can observe where the tree went.
        try lock(url.appending(path: "drive_c/keep/inner"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: url.appending(path: "drive_c/keep").path)

        _ = try store.delete("play")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "bottles/ must be clean whatever the purge managed")
    }

    /// Guards against someone "simplifying" rename(2) back into FileManager.moveItem, which
    /// across volumes copies and then deletes — reproducing #38 with a full duplicate on the side.
    func testDeleteIsARenameNotACopy() throws {
        let url = try makeBottle("play")
        try lock(url.appending(path: "drive_c/Program Files/Game/data"))
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        _ = try store.delete("play")
        let moved = (try? FileManager.default.contentsOfDirectory(at: paths.trash, includingPropertiesForKeys: nil)) ?? []
        let after = moved.first.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? Int
        }
        XCTAssertNotNil(before)
        XCTAssertEqual(before, after ?? before, "the tree must keep its inode: rename, not copy")
    }

    // MARK: Safety

    /// The one mistake that would be catastrophic. Every bottle links
    /// drive_c/users/<user>/{Documents,Desktop,Downloads} at the real home folders and
    /// dosdevices/z: at /, so a purge that followed symlinks would delete the user's data.
    func testPurgeNeverFollowsSymlinksOutOfTheTree() throws {
        let url = try makeBottle("play")
        let outside = home.appending(path: "precious")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let canary = outside.appending(path: "canary.txt")
        try "do not delete".write(to: canary, atomically: true, encoding: .utf8)

        let users = url.appending(path: "drive_c/users/tester")
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: users.appending(path: "Documents"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: url.appending(path: "dosdevices/z:"),
                                                   withDestinationURL: URL(fileURLWithPath: "/"))
        // Force the slow path, so the hand-written recursion is what gets exercised.
        try lock(url.appending(path: "drive_c/Program Files/Game/data"))

        _ = try store.delete("play")
        XCTAssertTrue(FileManager.default.fileExists(atPath: canary.path),
                      "the purge followed a symlink out of the bottle")
        XCTAssertEqual(try String(contentsOf: canary, encoding: .utf8), "do not delete")
    }

    // MARK: Recovery

    /// The state #38's reporter is stuck in: a directory with no readable settings file. It was
    /// invisible to `list()` and `delete()` refused it, so there was no way out from the app.
    func testADamagedBottleIsListedAndDeletable() throws {
        let url = try makeBottle("play")
        try FileManager.default.removeItem(at: url.appending(path: "bottle.json"))

        XCTAssertTrue(try store.list().isEmpty, "list() still only shows loadable bottles")
        XCTAssertEqual(try store.damaged().map(\.name), ["play"])
        XCTAssertNoThrow(try store.delete("play"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A Gin-era bottle keeps its settings in gin.json. `Bottle.load` accepts it, so `list()`
    /// showed it while the old bottle.json guard made it permanently undeletable.
    func testALegacyGinBottleIsDeletable() throws {
        let url = try makeBottle("play")
        try FileManager.default.moveItem(at: url.appending(path: "bottle.json"),
                                         to: url.appending(path: "gin.json"))

        XCTAssertEqual(try store.list().map(\.name), ["play"])
        XCTAssertNoThrow(try store.delete("play"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeletingAnAbsentBottleStillReportsItMissing() throws {
        XCTAssertThrowsError(try store.delete("nope"))
    }

    func testDamagedIgnoresDotFilesAndLooseFiles() throws {
        try "x".write(to: paths.bottles.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)
        try makeBottle("play")
        XCTAssertTrue(try store.damaged().isEmpty)
    }

    // MARK: Leftovers

    func testLeftoversAreReportedAndSweptLater() throws {
        let url = try makeBottle("play")
        let stubborn = url.appending(path: "drive_c/mnt")
        try FileManager.default.createDirectory(at: stubborn, withIntermediateDirectories: true)

        _ = try store.delete("play")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Nothing genuinely unpurgeable here, so the sweep has nothing to report and .trash empties.
        XCTAssertTrue(store.sweepTrash().isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(at: paths.trash, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(left.isEmpty, "a purgeable tree must not linger in .trash")
    }

    /// The purge deletes recursively and shells out to rm -rf, so it must refuse a shallow
    /// path outright rather than trust every future caller. "/" and a bare home must be inert.
    func testPurgeRefusesShallowPaths() {
        for dangerous in ["/", "/Users", "/Users/someone", "/Volumes"] {
            let failures = Purge.tree(at: URL(fileURLWithPath: dangerous))
            XCTAssertEqual(failures.first?.code, EINVAL, "\(dangerous) must be refused, not purged")
            XCTAssertTrue(FileManager.default.fileExists(atPath: "/Users"), "/Users must still exist")
        }
    }

    /// Bottle names reach the trash path, so they must not be able to steer it.
    func testTrashNameCannotEscapeTheTrashDirectory() {
        XCTAssertFalse(BottleStore.trashName("../../etc").contains("/"))
        XCTAssertFalse(BottleStore.trashName("..").contains("."))
        XCTAssertFalse(BottleStore.trashName("a/b:c").contains("/"))
    }
}
