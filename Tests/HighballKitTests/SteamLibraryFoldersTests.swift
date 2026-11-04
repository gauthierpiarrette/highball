import XCTest
@testable import HighballKit

/// Steam keeps more than one library folder, the second often on an external disk, and lists
/// them in libraryfolders.vdf as Windows paths. A game installed there was invisible to Highball
/// until highball-db#316 (Bloody Spell in a library on /Volumes/MEDIA_DEV).
final class SteamLibraryFoldersTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "hb-libfolders-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func manifest(_ appid: Int, _ name: String, dir: String) -> String {
        "\"AppState\"\n{\n\t\"appid\"\t\t\"\(appid)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"\(dir)\"\n}\n"
    }

    func testGamesInASecondLibraryFolderOnAnotherDriveAreFound() throws {
        let bottle = tmp.appending(path: "bottle", directoryHint: .isDirectory)
        let external = tmp.appending(path: "Disk/SteamLibrary", directoryHint: .isDirectory)
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        try write("", to: steam.appending(path: "steam.exe"))
        try write(manifest(400, "Portal", dir: "Portal"), to: steam.appending(path: "steamapps/appmanifest_400.acf"))
        try write(manifest(992300, "Bloody Spell", dir: "BloodySpell"), to: external.appending(path: "steamapps/appmanifest_992300.acf"))
        try write(manifest(400, "Portal (copy)", dir: "Portal2"), to: external.appending(path: "steamapps/appmanifest_400.acf"))
        let dosdevices = bottle.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dosdevices.appending(path: "c:").path, withDestinationPath: "../drive_c")
        try FileManager.default.createSymbolicLink(atPath: dosdevices.appending(path: "d:").path, withDestinationPath: tmp.appending(path: "Disk").path)
        try write("""
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
        \t\t"label"\t\t""
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"D:\\\\SteamLibrary"
        \t}
        \t"2"
        \t{
        \t\t"path"\t\t"E:\\\\Gone"
        \t}
        }
        """, to: steam.appending(path: "steamapps/libraryfolders.vdf"))

        let folders = SteamLibrary.libraryFolders(steamRoot: steam, bottleURL: bottle)
        XCTAssertEqual(folders.map(\.standardizedFileURL.path), [steam.standardizedFileURL.path, external.standardizedFileURL.path],
                       "the environment's own library first, then the external one; the unmapped drive is skipped")

        let games = SteamLibrary.games(steamRoot: steam, bottleURL: bottle)
        XCTAssertEqual(games.map(\.appid), [992300, 400])
        XCTAssertEqual(games.first { $0.appid == 400 }?.installdir, "Portal", "the environment's own copy wins over a second manifest of the same game")
        XCTAssertEqual(games.first { $0.appid == 992300 }?.installFolder?.standardizedFileURL.path,
                       external.appending(path: "steamapps/common/BloodySpell").standardizedFileURL.path)
    }

    func testTheLibraryListInConfigIsReadWhenSteamappsCantBe() throws {
        // highball#603: a Finder alias named steamapps is a file, so the list inside it can't be read.
        let bottle = tmp.appending(path: "alias-bottle", directoryHint: .isDirectory)
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let external = tmp.appending(path: "alias-external/SteamLibrary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: steam.appending(path: "config"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external.appending(path: "steamapps"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bottle.appending(path: "dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bottle.appending(path: "dosdevices/d:"), withDestinationURL: external.deletingLastPathComponent())
        try Data("alias".utf8).write(to: steam.appending(path: "steamapps"))
        try Data(#""libraryfolders" { "1" { "path" "D:\\\\SteamLibrary" } }"#.utf8).write(to: steam.appending(path: "config/libraryfolders.vdf"))
        let folders = SteamLibrary.libraryFolders(steamRoot: steam, bottleURL: bottle)
        XCTAssertEqual(folders.map(\.standardizedFileURL.path).last, external.standardizedFileURL.path)
    }

    func testASymlinkedSteamappsFolderIsRead() throws {
        // highball-db#316: steamapps moved to an external disk with a symlink left in its place.
        let bottle = tmp.appending(path: "bottle", directoryHint: .isDirectory)
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let external = tmp.appending(path: "MEDIA_DEV/roms/steam/steamapps", directoryHint: .isDirectory)
        try write("", to: steam.appending(path: "steam.exe"))
        try write(manifest(992300, "Bloody Spell", dir: "BloodySpell"), to: external.appending(path: "appmanifest_992300.acf"))
        try write("", to: external.appending(path: "common/BloodySpell/BloodySpell.exe"))
        try FileManager.default.createSymbolicLink(atPath: steam.appending(path: "steamapps").path, withDestinationPath: external.path)

        let games = SteamLibrary.games(steamRoot: steam, bottleURL: bottle)
        XCTAssertEqual(games.map(\.appid), [992300], "a symlinked steamapps must list its manifests")
        XCTAssertEqual(games.first?.installFolder?.resolvingSymlinksInPath().path,
                       external.appending(path: "common/BloodySpell").resolvingSymlinksInPath().path)
    }

    func testWindowsPathsGoThroughTheBottlesDriveLetters() throws {
        let bottle = tmp.appending(path: "b", directoryHint: .isDirectory)
        XCTAssertEqual(SteamLibrary.unixURL(windowsPath: "C:\\Games\\X", bottleURL: bottle)?.standardizedFileURL.path,
                       bottle.appending(path: "drive_c/Games/X").standardizedFileURL.path, "c: is drive_c even before dosdevices exists")
        XCTAssertEqual(SteamLibrary.unixURL(windowsPath: "Z:\\Volumes\\MEDIA_DEV\\roms\\steam", bottleURL: bottle)?.path, "/Volumes/MEDIA_DEV/roms/steam")
        XCTAssertNil(SteamLibrary.unixURL(windowsPath: "Q:\\Nowhere", bottleURL: bottle), "a letter the bottle does not map")
        XCTAssertNil(SteamLibrary.unixURL(windowsPath: "not a windows path", bottleURL: bottle))
        XCTAssertEqual(SteamLibrary.libraryPaths(in: #""path"        "D:\\SteamLibrary""#), ["D:\\SteamLibrary"])
    }

    func testTheInstallSignatureFollowsRecordsInEveryLibraryFolder() throws {
        // highball#286: an install finished in Steam and its page kept offering Install. The
        // watcher covered only the environment's own steamapps, and the client watch now compares
        // this signature, so a record written in any library folder counts.
        let bottle = tmp.appending(path: "bottle", directoryHint: .isDirectory)
        let external = tmp.appending(path: "Disk/SteamLibrary", directoryHint: .isDirectory)
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        try write("", to: steam.appending(path: "steam.exe"))
        try write(manifest(400, "Portal", dir: "Portal"), to: steam.appending(path: "steamapps/appmanifest_400.acf"))
        try FileManager.default.createDirectory(at: external.appending(path: "steamapps"), withIntermediateDirectories: true)
        let dosdevices = bottle.appending(path: "dosdevices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dosdevices.appending(path: "d:").path, withDestinationPath: tmp.appending(path: "Disk").path)
        try write("\"libraryfolders\"\n{\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"D:\\\\SteamLibrary\"\n\t}\n}\n",
                  to: steam.appending(path: "steamapps/libraryfolders.vdf"))

        XCTAssertEqual(SteamLibrary.steamappsDirectories(steamRoot: steam, bottleURL: bottle).map(\.path),
                       [steam.appending(path: "steamapps").resolvingSymlinksInPath().path,
                        external.appending(path: "steamapps").resolvingSymlinksInPath().path],
                       "the watcher gets the environment's own steamapps and the second library's")
        let before = SteamLibrary.installSignature(steamRoot: steam, bottleURL: bottle)
        XCTAssertEqual(SteamLibrary.installSignature(steamRoot: steam, bottleURL: bottle), before, "nothing written, nothing changed")
        let record = external.appending(path: "steamapps/appmanifest_221380.acf")
        try write(manifest(221380, "Age of Empires II (2013)", dir: "Age2HD"), to: record)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: record.path)
        let started = SteamLibrary.installSignature(steamRoot: steam, bottleURL: bottle)
        XCTAssertNotEqual(started, before, "a record appearing in the second library folder changes the signature")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: record.path)
        XCTAssertNotEqual(SteamLibrary.installSignature(steamRoot: steam, bottleURL: bottle), started,
                          "a rewritten record, the install finishing, changes it again")
    }
}
