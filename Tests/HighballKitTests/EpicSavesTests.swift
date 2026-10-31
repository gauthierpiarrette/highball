import XCTest
@testable import HighballKit

/// Epic cloud saves through legendary's sync-saves (EpicSaves): what legendary found, what a sync
/// then does, and that nothing replaces the Mac's saves without a copy and, when both changed, a
/// question.
final class EpicSavesTests: XCTestCase {
    /// legendary's log lines, as 0.21.0 writes them (legendary/cli.py sync_saves).
    func testStateComesFromLegendarysLog() {
        XCTAssertEqual(EpicSaves.state(in: ["[cli] INFO: No cloud or local savegame found."]), .nothing)
        XCTAssertEqual(EpicSaves.state(in: [#"[cli] INFO: Save game for "Game" is up to date, skipping..."#]), .inStep)
        XCTAssertEqual(EpicSaves.state(in: [#"[cli] INFO: Cloud save for "Game" is newer:"#, "[cli] INFO: - Cloud save date: 2026-10-31 12:00:00"]), .cloudNewer)
        XCTAssertEqual(EpicSaves.state(in: [#"[cli] INFO: Local save for "Game" is newer"#]), .localNewer)
        XCTAssertNil(EpicSaves.state(in: ["[cli] INFO: Got 0 remote save game(s)"]), "said nothing about the game: no folder resolved")
        XCTAssertTrue(EpicSaves.isFailure("[Core] ERROR: Failed to download save"))
    }

    /// Always -y and --accept-path: legendary would otherwise stop at a question no one can answer.
    func testArguments() {
        XCTAssertEqual(EpicSaves.arguments(app: "Garlic", direction: nil),
                       ["sync-saves", "Garlic", "-y", "--accept-path", "--skip-upload", "--skip-download"])
        XCTAssertEqual(EpicSaves.arguments(app: "Garlic", direction: .download).suffix(1), ["--skip-upload"])
        XCTAssertEqual(EpicSaves.arguments(app: "Garlic", direction: .upload).suffix(1), ["--skip-download"])
        XCTAssertEqual(EpicSaves.arguments(app: "Garlic", direction: .forceDownload).suffix(1), ["--force-download"])
    }

    /// A download over saves changed since the last sync is asked, never decided by age.
    func testADownloadOverChangedSavesIsAConflict() {
        let synced = Date(timeIntervalSince1970: 1_790_000_000)
        let later = synced.addingTimeInterval(3_600)
        XCTAssertEqual(EpicSaves.decide(.cloudNewer, direction: .download, lastChange: later, lastSync: synced), .conflict)
        XCTAssertEqual(EpicSaves.decide(.cloudNewer, direction: .download, lastChange: later, lastSync: nil), .conflict, "never synced: asked")
        XCTAssertEqual(EpicSaves.decide(.cloudNewer, direction: .download, lastChange: synced, lastSync: synced), .transfer(download: true))
        XCTAssertEqual(EpicSaves.decide(.cloudNewer, direction: .download, lastChange: nil, lastSync: nil), .transfer(download: true), "nothing here to lose")
    }

    func testEachDirectionTakesOnlyItsOwnSide() {
        XCTAssertEqual(EpicSaves.decide(.localNewer, direction: .download, lastChange: nil, lastSync: nil), .leave)
        XCTAssertEqual(EpicSaves.decide(.cloudNewer, direction: .upload, lastChange: nil, lastSync: nil), .leave)
        XCTAssertEqual(EpicSaves.decide(.localNewer, direction: .upload, lastChange: nil, lastSync: nil), .transfer(download: false))
        XCTAssertEqual(EpicSaves.decide(.inStep, direction: .download, lastChange: nil, lastSync: nil), .inStep)
        XCTAssertEqual(EpicSaves.decide(.inStep, direction: .forceUpload, lastChange: nil, lastSync: nil), .transfer(download: false))
    }

    /// Cloud saves are a game's when its catalog item names a folder for them.
    func testCloudSaveSupportComesFromLegendarysMetadata() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "epic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let saves = EpicSaves(store: EpicStore(paths: HighballPaths(home: home)))
        let metadata = home.appending(path: "legendary/metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try #"{"app_name":"Garlic","metadata":{"customAttributes":{"CloudSaveFolder":{"type":"STRING","value":"{AppData}/../LocalLow/Dodge Roll/Enter the Gungeon"}}}}"#
            .write(to: metadata.appending(path: "Garlic.json"), atomically: true, encoding: .utf8)
        try #"{"app_name":"Duck","metadata":{"customAttributes":{}}}"#.write(to: metadata.appending(path: "Duck.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(saves.supportsCloudSaves("Garlic"))
        XCTAssertFalse(saves.supportsCloudSaves("Duck"))
        XCTAssertFalse(saves.supportsCloudSaves("Missing"))
    }
}
