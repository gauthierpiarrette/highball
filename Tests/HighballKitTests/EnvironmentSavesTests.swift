import XCTest
@testable import HighballKit

/// Keeping an environment's saves before it is deleted: the right folders, nothing bulky, links
/// followed only inside the environment, and a copy that is whole or absent.
final class EnvironmentSavesTests: XCTestCase {
    private var root: URL!
    private var env: URL!
    private var user: URL!
    private var macHome: URL!
    private var backups: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "envsaves-\(UUID().uuidString)")
        env = root.appending(path: "bottles/Games")
        user = env.appending(path: "drive_c/users/tester")
        macHome = root.appending(path: "mac-home")
        backups = root.appending(path: "save-backups")
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        try fm.createDirectory(at: env.appending(path: "drive_c/users/Public/Documents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: macHome.appending(path: "Documents"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ path: String, in dir: URL, bytes: Int = 1) throws {
        let url = dir.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x78, count: bytes).write(to: url)
    }

    private func files() -> [String] {
        EnvironmentSaves.entries(environment: env).filter { !$0.isDirectory }.map(\.path).sorted()
    }

    func testKeepsTheSaveFoldersAndLeavesOutTheBulk() throws {
        try write("Saved Games/Remedy/Control/save1.sav", in: user)
        try write("AppData/Roaming/Game/profile.cfg", in: user)
        try write("AppData/LocalLow/Studio/Game/slot.dat", in: user)
        try write("AppData/Local/Game/Saved/SaveGames/0.sav", in: user)
        try write("AppData/Local/Game/ShaderCache/big.bin", in: user)
        try write("AppData/Local/Game/Saved/Logs/game.log", in: user)
        try write("AppData/Local/Steam/htmlcache/index", in: user)
        try write("AppData/Local/Steam/config.vdf", in: user)
        try write("AppData/Local/Microsoft/Windows/x.dat", in: user)
        try write("AppData/Local/Temp/setup.tmp", in: user)
        try write("AppData/Roaming/Other/GPUCache/data_0", in: user)
        try write("AppData/Roaming/Microsoft/settings.dat", in: user)
        try write("Contacts/x.contact", in: user)
        XCTAssertEqual(files(), [
            "tester/AppData/Local/Game/Saved/SaveGames/0.sav",
            "tester/AppData/LocalLow/Studio/Game/slot.dat",
            "tester/AppData/Roaming/Game/profile.cfg",
            "tester/AppData/Roaming/Microsoft/settings.dat",
            "tester/Saved Games/Remedy/Control/save1.sav",
        ], "Steam and Microsoft are left out under Local only")
    }

    func testDocumentsCountsOnlyWhenItIsInside() throws {
        try write("My Games/mac.sav", in: macHome.appending(path: "Documents"))
        try fm.createSymbolicLink(at: user.appending(path: "Documents"), withDestinationURL: macHome.appending(path: "Documents"))
        XCTAssertEqual(files(), [], "the link to the Mac's Documents is never walked")
        try fm.removeItem(at: user.appending(path: "Documents"))
        try write("Documents/My Games/inside.sav", in: user)
        XCTAssertEqual(files(), ["tester/Documents/My Games/inside.sav"])
    }

    func testLinksAreFollowedOnlyInsideTheEnvironmentAndLoopsOnce() throws {
        let roaming = user.appending(path: "AppData/Roaming")
        try write("Game/a.sav", in: roaming)
        try write("drive_c/GameData/saves/b.sav", in: env)
        try write("secret.txt", in: macHome)
        try fm.createSymbolicLink(at: roaming.appending(path: "Linked"), withDestinationURL: env.appending(path: "drive_c/GameData/saves"))
        try fm.createSymbolicLink(at: roaming.appending(path: "Home"), withDestinationURL: macHome)
        try fm.createSymbolicLink(at: roaming.appending(path: "Gone"), withDestinationURL: env.appending(path: "nowhere"))
        try fm.createSymbolicLink(at: roaming.appending(path: "Game/Loop"), withDestinationURL: roaming)
        try fm.createSymbolicLink(at: roaming.appending(path: "Game/one.sav"), withDestinationURL: roaming.appending(path: "Game/a.sav"))
        XCTAssertEqual(files(), [
            "tester/AppData/Roaming/Game/a.sav",
            "tester/AppData/Roaming/Game/one.sav",
            "tester/AppData/Roaming/Linked/b.sav",
        ])
    }

    func testKeepCopiesCompleteUnderTheDatedName() throws {
        try write("Saved Games/Game/save.sav", in: user, bytes: 10)
        try write("AppData/Roaming/Game/cfg.ini", in: user, bytes: 5)
        XCTAssertEqual(EnvironmentSaves.bytes(environment: env), 15)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = try XCTUnwrap(try EnvironmentSaves.keep(environment: env, name: "Games", backups: backups, date: date))
        XCTAssertEqual(kept.bytes, 15)
        XCTAssertEqual(kept.folder.deletingLastPathComponent().lastPathComponent, "environments")
        XCTAssertTrue(kept.folder.lastPathComponent.hasPrefix("Games-2027-01-"))
        XCTAssertEqual(try Data(contentsOf: kept.folder.appending(path: "tester/Saved Games/Game/save.sav")).count, 10)
        XCTAssertTrue(fm.fileExists(atPath: kept.folder.appending(path: "tester/AppData/Roaming/Game/cfg.ini").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: kept.folder.deletingLastPathComponent().path), [kept.folder.lastPathComponent], "no .partial left behind")
    }

    func testNothingToKeepMakesNoFolder() throws {
        try fm.createDirectory(at: user.appending(path: "Saved Games"), withIntermediateDirectories: true)
        XCTAssertNil(try EnvironmentSaves.keep(environment: env, name: "Games", backups: backups))
        XCTAssertFalse(fm.fileExists(atPath: backups.path))
    }

    func testAFailedCopyLeavesNothingAndSaysWhy() throws {
        try write("Saved Games/Game/save.sav", in: user)
        try fm.createDirectory(at: backups.appending(path: "environments"), withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: backups.appending(path: "environments").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backups.appending(path: "environments").path) }
        XCTAssertThrowsError(try EnvironmentSaves.keep(environment: env, name: "Games", backups: backups)) { error in
            XCTAssertTrue("\(error)".contains("was not deleted"))
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: backups.appending(path: "environments").path), [])
    }
}
