import XCTest
@testable import HighballKit

/// Epic cloud saves through legendary's sync-saves (EpicSaves): reading legendary's log, deciding
/// from what changed on each side, and which folders are never synced. EpicFakeLegendaryTests
/// runs whole syncs.
final class EpicSavesTests: XCTestCase {
    /// legendary's log lines, as 0.21.0 writes them (legendary/cli.py sync_saves).
    func testStateAndCloudDateComeFromLegendarysLog() {
        XCTAssertEqual(EpicSaves.check(in: ["[cli] INFO: No cloud or local savegame found."]), .init(state: .nothing, cloud: nil))
        XCTAssertEqual(EpicSaves.check(in: ["[Core] DEBUG: Local save date: 2026-11-01 01:36:04.5+00:00, Remote save date: 2026-11-01 01:36:04+00:00",
                                            #"[cli] INFO: Save game for "Game" is up to date, skipping..."#]),
                       .init(state: .inStep, cloud: "2026-11-01 01:36:04"))
        XCTAssertEqual(EpicSaves.check(in: [#"[cli] INFO: Cloud save for "Game" is newer:"#, "[cli] INFO: - Cloud save date: 2026-10-31 12:00:00",
                                            "[cli] INFO: - Local save date: N/A"]),
                       .init(state: .cloudNewer, cloud: "2026-10-31 12:00:00"))
        XCTAssertEqual(EpicSaves.check(in: [#"[cli] INFO: Local save for "Game" is newer"#, "[cli] INFO: - Cloud save date: N/A"]),
                       .init(state: .localNewer, cloud: nil))
        XCTAssertNil(EpicSaves.check(in: ["[cli] INFO: Got 0 remote save game(s)"]), "said nothing about the game")
    }

    /// A download that skipped a chunk or a file part only warns, and still "completes".
    func testFailuresIncludeTheWarningsOfAnIncompleteDownload() {
        XCTAssertTrue(EpicSaves.isFailure("[Core] ERROR: Download failed, status code: 500"))
        XCTAssertTrue(EpicSaves.isFailure("[Core] CRITICAL: No chunks were available, aborting."))
        XCTAssertTrue(EpicSaves.isFailure("[Core] WARNING: Chunk a/b not in file list, save data may be incomplete!"))
        XCTAssertTrue(EpicSaves.isFailure(#"[SGH] WARNING: Got EOF for "x" with 3 bytes remaining! File may have been corrupted/modified."#))
        XCTAssertFalse(EpicSaves.isFailure("[cli] INFO: Got 1 remote save game(s)"))
    }

    func testFailuresAreExplainedByCause() {
        XCTAssertTrue(EpicSaves.explanation(["[cli] ERROR: Login failed! Cannot continue with download process."]).contains("sign-in"))
        XCTAssertTrue(EpicSaves.explanation(["[cli] ERROR: Unable to lock install data, cannot modify save path."]).contains("busy"))
        XCTAssertTrue(EpicSaves.explanation(["[cli] WARNING: Path contains unprocessed variables, please enter the correct path manually."]).contains("work out"))
        XCTAssertEqual(EpicSaves.explanation([]), "legendary said nothing about this game's saves")
    }

    /// Always -y and --accept-path (legendary would otherwise stop at a question no one can
    /// answer), and -v for the cloud save's date.
    func testArguments() {
        XCTAssertEqual(EpicSaves.arguments(app: "Garlic", direction: nil),
                       ["-v", "sync-saves", "Garlic", "-y", "--accept-path", "--skip-upload", "--skip-download"])
        XCTAssertEqual(EpicSaves.arguments(app: "Garlic", direction: .download).suffix(1), ["--skip-upload"])
        XCTAssertEqual(EpicSaves.arguments(app: "Garlic", direction: .upload).suffix(1), ["--skip-download"])
        XCTAssertEqual(EpicSaves.arguments(app: "Garlic", direction: .forceDownload).suffix(1), ["--force-download"])
    }

    private let synced = Date(timeIntervalSince1970: 1_790_000_000)
    private func record(cloud: String?) -> EpicSaves.Record { .init(synced: synced, cloud: cloud, path: "/saves") }

    /// Which side changed since the last sync decides, in both directions; age never does.
    func testDecisionsComeFromWhatChangedOnEachSide() {
        let seen = record(cloud: "2026-10-01 10:00:00")
        let later = synced.addingTimeInterval(3_600)
        let newCloud = EpicSaves.Check(state: .localNewer, cloud: "2026-10-02 10:00:00")
        // Both changed, even with the Mac newer by age: asked.
        XCTAssertEqual(EpicSaves.decide(newCloud, direction: .download, record: seen, lastChange: later, hasLocal: true), .conflict(firstSync: false))
        XCTAssertEqual(EpicSaves.decide(newCloud, direction: .upload, record: seen, lastChange: later, hasLocal: true), .conflict(firstSync: false))
        // Only the cloud changed: down before Play, left after the game.
        let cloudOnly = EpicSaves.Check(state: .cloudNewer, cloud: "2026-10-02 10:00:00")
        XCTAssertEqual(EpicSaves.decide(cloudOnly, direction: .download, record: seen, lastChange: synced, hasLocal: true), .transfer(download: true))
        XCTAssertEqual(EpicSaves.decide(cloudOnly, direction: .upload, record: seen, lastChange: synced, hasLocal: true), .leave)
        // Only the Mac changed: left before Play, up after the game.
        let macOnly = EpicSaves.Check(state: .localNewer, cloud: "2026-10-01 10:00:00")
        XCTAssertEqual(EpicSaves.decide(macOnly, direction: .download, record: seen, lastChange: later, hasLocal: true), .leave)
        XCTAssertEqual(EpicSaves.decide(macOnly, direction: .upload, record: seen, lastChange: later, hasLocal: true), .transfer(download: false))
        XCTAssertEqual(EpicSaves.decide(.init(state: .inStep, cloud: "x"), direction: .download, record: nil, lastChange: later, hasLocal: true), .inStep)
    }

    /// A change to the saves right after a sync still counts: the folder's summary differs, even
    /// within legendary's 60 seconds.
    func testAChangeSoonAfterASyncCounts() {
        var seen = record(cloud: "2026-10-01 10:00:00")
        seen.local = "1 10 1790000000.0"
        let macNewer = EpicSaves.Check(state: .localNewer, cloud: "2026-10-01 10:00:00")
        XCTAssertEqual(EpicSaves.decide(macNewer, direction: .upload, record: seen, lastChange: synced.addingTimeInterval(5),
                                        hasLocal: true, fingerprint: "1 12 1790000005.0"), .transfer(download: false))
        XCTAssertEqual(EpicSaves.decide(macNewer, direction: .upload, record: seen, lastChange: synced.addingTimeInterval(5),
                                        hasLocal: true, fingerprint: seen.local), .leave)
    }

    func testAFirstSyncAsksOnlyWithSavesOnBothSides() {
        let both = EpicSaves.Check(state: .cloudNewer, cloud: "2026-10-02 10:00:00")
        XCTAssertEqual(EpicSaves.decide(both, direction: .download, record: nil, lastChange: synced, hasLocal: true), .conflict(firstSync: true))
        XCTAssertEqual(EpicSaves.decide(both, direction: .download, record: nil, lastChange: nil, hasLocal: false), .transfer(download: true), "nothing here to lose")
        let macOnly = EpicSaves.Check(state: .localNewer, cloud: nil)
        XCTAssertEqual(EpicSaves.decide(macOnly, direction: .upload, record: nil, lastChange: synced, hasLocal: true), .transfer(download: false), "an empty cloud")
    }

    /// The first version kept only the date: a cloud save newer than it came from elsewhere.
    func testARecordFromBeforeTheCloudWasKept() {
        let old = EpicSaves.Record(synced: synced)
        let afterSync = EpicSaves.Check(state: .cloudNewer, cloud: "2026-12-01 00:00:00")
        let beforeSync = EpicSaves.Check(state: .localNewer, cloud: "2026-09-01 00:00:00")
        XCTAssertEqual(EpicSaves.decide(afterSync, direction: .download, record: old, lastChange: synced, hasLocal: true), .transfer(download: true))
        XCTAssertEqual(EpicSaves.decide(beforeSync, direction: .upload, record: old, lastChange: synced.addingTimeInterval(600), hasLocal: true), .transfer(download: false))
    }

    /// Filters as legendary matches them: a directory prefix, a suffix, or an fnmatch wildcard.
    func testFiltersMatchLikeLegendary() {
        let filter = SaveFilter(includeList: "Saved/,*.sav,profile.dat", excludeList: "Saved/cache/")
        XCTAssertTrue(filter.matches("Saved/slot1"))
        XCTAssertTrue(filter.matches("deep/dir/game.sav"))
        XCTAssertTrue(filter.matches("x/profile.dat"))
        XCTAssertFalse(filter.matches("Saved/cache/blob"))
        XCTAssertFalse(filter.matches("Binaries/Game.exe"))
        XCTAssertTrue(SaveFilter.everything.matches("anything"))
    }

    /// Folders holding more than the game's saves are never synced: a download would empty them.
    func testBroadFoldersAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "epic-broad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home"), prefix = root.appending(path: "Env")
        let user = prefix.appending(path: "drive_c/users/player")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let install = prefix.appending(path: "drive_c/Games/Game")
        func refused(_ folder: URL, _ filter: SaveFilter = .everything) -> Bool {
            EpicSaves.refusal(for: folder, install: install, prefix: prefix, home: home, filter: filter) != nil
        }
        for broad in [home, home.appending(path: "Documents"), home.appending(path: "Library/Application Support"),
                      root, prefix, user.appending(path: "AppData/Local"), user.appending(path: "documents/my games"),
                      install, install.deletingLastPathComponent()] {
            XCTAssertTrue(refused(broad), broad.path)
        }
        XCTAssertFalse(refused(user.appending(path: "AppData/Local/Game/Saved")))
        XCTAssertFalse(refused(home.appending(path: "Library/Application Support/Dodge Roll/Enter the Gungeon")))
        XCTAssertFalse(refused(install.appending(path: "Saves")))
        XCTAssertFalse(refused(install, SaveFilter(includeList: "Saves/", excludeList: nil)), "an include list limits it to the saves")
    }

    /// Cloud saves are a game's when its catalog item names a folder for them.
    func testCloudSaveSupportComesFromLegendarysMetadata() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "epic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let saves = EpicSaves(store: EpicStore(paths: HighballPaths(home: home)))
        let metadata = home.appending(path: "legendary/metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try #"{"app_name":"Garlic","metadata":{"customAttributes":{"CloudSaveFolder":{"type":"STRING","value":"{AppData}/../LocalLow/Dodge Roll/Enter the Gungeon"},"CloudIncludeList":{"type":"STRING","value":"*.sav"}}}}"#
            .write(to: metadata.appending(path: "Garlic.json"), atomically: true, encoding: .utf8)
        try #"{"app_name":"Duck","metadata":{"customAttributes":{}}}"#.write(to: metadata.appending(path: "Duck.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(saves.supportsCloudSaves("Garlic"))
        XCTAssertFalse(saves.supportsCloudSaves("Garlic", mac: true))
        XCTAssertEqual(saves.catalog("Garlic")?.filter, SaveFilter(include: ["*.sav"], exclude: nil))
        XCTAssertFalse(saves.supportsCloudSaves("Duck"))
        XCTAssertFalse(saves.supportsCloudSaves("Missing"))
    }
}
