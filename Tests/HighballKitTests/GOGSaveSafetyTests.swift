import XCTest
@testable import HighballKit

/// No sync replaces or deletes a save without a copy of it kept first (GOGSaves' backups).
final class GOGSaveSafetyTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appending(path: "saves-\(UUID().uuidString)") }
    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "Game/saves/locked").path)
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(install: String = "Game") throws -> (GOGSaves, GOGStore.InstalledGame, GOGSaves.Location, URL) {
        let saves = GOGSaves(store: GOGStore(paths: HighballPaths(home: root.appending(path: "home"))))
        let folder = root.appending(path: "\(install)/saves")
        try FileManager.default.createDirectory(at: folder.appending(path: "slot1"), withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: folder.appending(path: "slot1/save.dat"))
        let game = GOGStore.InstalledGame(id: "1", title: "Game", folder: root.appending(path: install), buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
        return (saves, game, GOGSaves.Location(name: "saves", template: "<?INSTALL?>/saves"), folder)
    }

    /// The copy comes before gogdl is asked: here gogdl is not even installed, and the copy is made.
    func testADownloadCopiesTheSavesBeforeAnythingRuns() throws {
        let (saves, game, location, folder) = try fixture()
        guard case .failed = saves.sync(game, location: location, folder: folder, direction: .download) else { return XCTFail("gogdl is absent here") }
        let copy = try XCTUnwrap(saves.backups(in: saves.backupsFolder(game, location)).first)
        XCTAssertEqual(try String(contentsOf: copy.appending(path: "slot1/save.dat"), encoding: .utf8), "progress")
    }

    func testAnUnchangedFolderIsNotCopiedTwice() throws {
        let (saves, game, location, folder) = try fixture()
        let first = try XCTUnwrap(try saves.backUpLocal(game, location: location, folder: folder))
        XCTAssertEqual(try saves.backUpLocal(game, location: location, folder: folder)?.lastPathComponent, first.lastPathComponent)
        try Data("more".utf8).write(to: folder.appending(path: "slot1/save.dat"))
        XCTAssertNotEqual(try saves.backUpLocal(game, location: location, folder: folder)?.lastPathComponent, first.lastPathComponent)
    }

    /// Kept by when they were made, never by name, and never the copy just made: a clock that was
    /// once ahead leaves copies dated later than today's.
    func testPruningKeepsTheNewestTenAndNeverTheCopyJustMade() throws {
        let (saves, game, location, folder) = try fixture()
        let dir = saves.backupsFolder(game, location)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<12 {
            let old = dir.appending(path: "9999-01-\(String(format: "%02d", i + 1))-mac")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(86_400 * Double(i + 1))], ofItemAtPath: old.path)
        }
        let copy = try XCTUnwrap(try saves.backUpLocal(game, location: location, folder: folder))
        let kept = saves.backups(in: dir)
        XCTAssertEqual(kept.count, 10)
        XCTAssertTrue(kept.map(\.lastPathComponent).contains(copy.lastPathComponent))
    }

    func testAFailedCopyLeavesNothingBehindAndStopsTheSync() throws {
        let (saves, game, location, folder) = try fixture()
        let locked = folder.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appending(path: "f"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        guard case let .failed(why) = saves.sync(game, location: location, folder: folder, direction: .download) else { return XCTFail() }
        XCTAssertTrue(why.contains("backed up"))
        let dir = saves.backupsFolder(game, location)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [], [], "no half copy, no .partial")
    }

    /// gogdl lists and deletes hidden files too, so they count as saves to keep.
    func testHiddenFilesCount() throws {
        let folder = root.appending(path: "Hidden")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: ".save"))
        XCTAssertEqual(GOGSaves.files(in: folder).map(\.lastPathComponent), [".save"])
    }

    func testTwoInstallsKeepTheirOwnBackups() throws {
        let (saves, a, location, _) = try fixture(install: "A")
        let (_, b, _, _) = try fixture(install: "B")
        XCTAssertNotEqual(saves.backupsFolder(a, location), saves.backupsFolder(b, location))
        XCTAssertEqual(saves.backupsFolder(a, location), saves.backupsFolder(a, location))
    }

    /// gogdl exits 0 when a file failed to come down; its log line fails the cloud copy instead,
    /// except for a location whose name another one's starts with: gogdl lists the other's files
    /// for it too and fails each at the wrong path, in a line that names no file.
    func testAFileGogdlFailedToFetchFailsTheCopy() {
        let own = GOGSaves.Location(name: "saves_profiles", template: "")
        XCTAssertTrue(GOGSaves.isFailure("[SAVES] ERROR: Downloading file failed", location: own))
        XCTAssertFalse(GOGSaves.isFailure("[SAVES] INFO: Files in cloud: 3", location: own))
        let prefix = GOGSaves.Location(name: "saves", template: "", sharesItsPrefix: true)
        XCTAssertFalse(GOGSaves.isFailure("[SAVES] ERROR: Downloading file failed", location: prefix))
        XCTAssertTrue(GOGSaves.isFailure("[SAVES] ERROR: There was an error uploading a file ", location: prefix))
    }

    /// An upload always copies GOG's cloud first: with gogdl absent here, the copy is what fails.
    func testAnUploadCopiesTheCloudFirst() throws {
        let (saves, game, location, folder) = try fixture()
        guard case let .failed(why) = saves.sync(game, location: location, folder: folder, direction: .upload) else { return XCTFail() }
        XCTAssertTrue(why.contains("backed up"))
    }

    /// A save folder years old: its copy is dated now, so the newest copies are still the ones kept.
    func testACopyOfAnOldFolderIsDatedNow() throws {
        let (saves, game, location, folder) = try fixture()
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: folder.path)
        let copy = try XCTUnwrap(try saves.backUpLocal(game, location: location, folder: folder))
        let made = try XCTUnwrap(try copy.resourceValues(forKeys: [.creationDateKey]).creationDate)
        XCTAssertLessThan(abs(made.timeIntervalSinceNow), 60)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appending(path: ".highball-backup").path), "nothing of Highball's inside the copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: GOGSaves.fingerprintFile(of: copy).path))
    }

    func testARefusalMovesNothing() {
        XCTAssertTrue(GOGSaves.isRefusal("[SAVES] WARNING: Refused to download files, newer files locally"))
        XCTAssertFalse(GOGSaves.isRefusal("[SAVES] INFO: Done"))
    }

    // MARK: Against a stand-in gogdl

    /// A stand-in for gogdl at the path GOGStore runs, keeping its cloud in a folder: listing by
    /// name prefix, downloads of newer cloud files only, an upload deleting cloud files the Mac
    /// lacks, refusals, conflicts, a timestamp glued to the next line, as gogdl 1.3.1 does.
    private func fakeGogdl(for saves: GOGSaves) throws -> URL {
        let cloud = root.appending(path: "cloud", directoryHint: .isDirectory)
        let binary = saves.store.gogdlBinary
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try #"""
        #!/bin/sh
        # gogdl 1.3.1's save-sync (gogdl/saves.py), with a folder standing in for GOG's cloud: a cloud
        # file's modification date is its last_modified.
        cloud="\#(cloud.path)"
        [ "$1" = --auth-config-path ] && shift 2
        [ "$1" = save-sync ] || exit 2
        dir="$2"; ts=0; tsArg=0; name=__default; prefered=""
        shift 3
        while [ $# -gt 0 ]; do
          case "$1" in
            --ts) tsArg="$2"; ts="${2%%.*}"; shift 2 ;;
            --name) name="$2"; shift 2 ;;
            --os) shift 2 ;;
            --skip-download) prefered=upload; shift ;;
            --skip-upload) prefered=download; shift ;;
            --force-upload) prefered=forceupload; shift ;;
            --force-download) prefered=forcedownload; shift ;;
            *) shift ;;
          esac
        done
        mkdir -p "$dir" "$cloud"
        mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
        localFiles() { (cd "$dir" && find . -type f | sed 's|^\./||'); }
        # is_in_our_dir: startswith(name), so "saves" lists "saves_profiles/..." too.
        cloudNames() { (cd "$cloud" && find . -type f | sed 's|^\./||' | while IFS= read -r n; do case "$n" in "$name"*) echo "$n" ;; esac; done); }
        # name.replace(f"{dirname}/", "", 1): the first occurrence, wherever it is.
        rel() { case "$1" in *"$name/"*) echo "${1%%"$name/"*}${1#*"$name/"}" ;; *) echo "$1" ;; esac; }
        # GOG answers an error for a path it has no file at; a file named *.unserved stands for one it
        # fails to serve.
        download() {
          case "$1" in *.unserved) echo "[SAVES] ERROR: Downloading file failed"; return ;; esac
          [ -f "$cloud/$name/$1" ] || { echo "[SAVES] ERROR: Downloading file failed"; return; }
          mkdir -p "$(dirname "$dir/$1")"; cp -p "$cloud/$name/$1" "$dir/$1"
        }
        upload() { mkdir -p "$(dirname "$cloud/$name/$1")"; cp -p "$dir/$1" "$cloud/$name/$1"; }
        lines() { printf '%s\n' "$1" | while IFS= read -r r; do [ -n "$r" ] && echo "$r"; done; }
        finish() { printf '%s' "$(date +%s)"; echo "[SAVES] INFO: Done"; exit 0; }
        localList=$(localFiles); remote=$(cloudNames)
        echo "[SAVES] INFO: Local files: $(lines "$localList" | wc -l | tr -d ' ')"
        if [ -n "$localList" ] && [ -z "$remote" ]; then
          echo "[SAVES] INFO: No files in cloud, uploading"
          lines "$localList" | while IFS= read -r r; do upload "$r"; done; finish
        elif [ -z "$localList" ] && [ -n "$remote" ]; then
          echo "[SAVES] INFO: No files locally, downloading"
          lines "$remote" | while IFS= read -r n; do download "$(rel "$n")"; done; finish
        fi
        newerLocal=$(lines "$localList" | while IFS= read -r r; do [ "$(mtime "$dir/$r")" -gt "$ts" ] && echo "$r"; done)
        newerCloud=$(lines "$remote" | while IFS= read -r n; do [ "$(mtime "$cloud/$n")" -gt "$ts" ] && rel "$n"; done)
        if [ -z "$newerLocal" ] && [ -n "$newerCloud" ]; then action=download
        elif [ -n "$newerLocal" ] && [ -z "$newerCloud" ]; then action=upload
        elif [ -z "$newerLocal" ] && [ -z "$newerCloud" ]; then action=none
        else action=conflict; fi
        case "$prefered" in
          forceupload) echo "[SAVES] WARNING: Forcing upload"; newerLocal="$localList"; action=upload ;;
          forcedownload) echo "[SAVES] WARNING: Forcing download"; newerCloud=$(lines "$remote" | while IFS= read -r n; do rel "$n"; done); action=download ;;
          upload) [ "$action" = download ] && { echo "[SAVES] WARNING: Refused to upload files, newer files in the cloud"; echo "$tsArg"; exit 0; } ;;
          download) [ "$action" = upload ] && { echo "[SAVES] WARNING: Refused to download files, newer files locally"; echo "$tsArg"; exit 0; } ;;
        esac
        case "$action" in
          upload)
            lines "$newerLocal" | while IFS= read -r r; do upload "$r"; done
            lines "$remote" | while IFS= read -r n; do r=$(rel "$n"); [ -f "$dir/$r" ] || { echo "[SAVES] INFO: DELETING IN CLOUD $r"; rm -f "$cloud/$name/$r"; }; done ;;
          download)
            lines "$newerCloud" | while IFS= read -r r; do download "$r"; done
            lines "$localList" | while IFS= read -r r; do [ -f "$cloud/$name/$r" ] || { echo "[SAVES] INFO: DELETING LOCALLY $r"; rm -f "$dir/$r"; }; done ;;
          conflict) echo "[SAVES] WARNING: Files in conflict force downloading or uploading of files" ;;
          none) echo "[SAVES] INFO: Nothing to do" ;;
        esac
        finish
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return cloud
    }

    private func write(_ text: String, to file: URL, at date: Date) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private func setLastSync(_ saves: GOGSaves, _ game: GOGStore.InstalledGame, _ location: GOGSaves.Location, _ date: Date) throws {
        var all = saves.timestamps()
        all[saves.key(game, location)] = String(Int(date.timeIntervalSince1970))
        try FileManager.default.createDirectory(at: saves.timestampsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: saves.timestampsFile)
    }

    /// Owner review on #589: with `saves` and `saves_profiles` (Crysis's layout), gogdl lists
    /// saves_profiles' files for `saves` too and fails each at the wrong path. That fails neither
    /// `saves`' sync nor its cloud copy, so the timestamp is kept and the next sync does not wedge;
    /// a file that really fails to come down still fails a location that shares no prefix.
    func testTwoLocationsSharingAPrefixSyncAgainstGogdl() throws {
        let (saves, game, _, folder) = try fixture()
        let cloud = try fakeGogdl(for: saves)
        let json = #"{"content":{"Windows":{"cloudStorage":{"enabled":true,"locations":[{"name":"saves","location":"<?INSTALL?>/saves"},{"name":"saves_profiles","location":"<?INSTALL?>/saves_profiles"}]}}}}"#
        let locations = try XCTUnwrap(GOGSaves.parseLocations(Data(json.utf8), clientID: "c"))
        XCTAssertEqual(locations.map(\.sharesItsPrefix), [true, false])
        let (ownSaves, profiles) = (locations[0], locations[1])
        let profilesFolder = root.appending(path: "Game/saves_profiles")
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3000)], ofItemAtPath: folder.appending(path: "slot1/save.dat").path)
        try write("from the cloud", to: cloud.appending(path: "saves/slot1/save.dat"), at: now.addingTimeInterval(-1000))
        try write("profile", to: cloud.appending(path: "saves_profiles/profile.dat"), at: now.addingTimeInterval(-1000))
        try setLastSync(saves, game, ownSaves, now.addingTimeInterval(-2000))
        let before = saves.timestamps()[saves.key(game, ownSaves)]

        XCTAssertEqual(saves.sync(game, location: ownSaves, folder: folder, direction: .download), .synced)
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "slot1/save.dat"), encoding: .utf8), "from the cloud")
        XCTAssertNotEqual(saves.timestamps()[saves.key(game, ownSaves)], before, "the sync's timestamp is kept")
        XCTAssertEqual(saves.sync(game, location: profiles, folder: profilesFolder, direction: .download), .synced)
        XCTAssertEqual(try String(contentsOf: profilesFolder.appending(path: "profile.dat"), encoding: .utf8), "profile")

        let copy = try saves.backUpCloud(game, location: ownSaves)
        XCTAssertEqual(try String(contentsOf: copy.appending(path: "slot1/save.dat"), encoding: .utf8), "from the cloud")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appending(path: "saves_profiles").path), "nothing of the other location's")
        XCTAssertEqual(saves.sync(game, location: ownSaves, folder: folder, direction: .forceUpload), .synced, "keeping this Mac's saves works")

        // GOG failing to serve one of saves_profiles' own files still fails its copy and its sync.
        try write("lost", to: cloud.appending(path: "saves_profiles/broken.unserved"), at: now.addingTimeInterval(600))
        XCTAssertThrowsError(try saves.backUpCloud(game, location: profiles))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: saves.backupsFolder(game, profiles).path)) ?? []
        XCTAssertFalse(names.contains { $0.hasSuffix(".partial") }, "no half copy")
        let kept = saves.timestamps()[saves.key(game, profiles)]
        guard case .failed = saves.sync(game, location: profiles, folder: profilesFolder, direction: .download) else { return XCTFail() }
        XCTAssertEqual(saves.timestamps()[saves.key(game, profiles)], kept, "a failed sync keeps no timestamp")
    }

    /// Owner review on #589: a cloud file older than the last sync and missing on the Mac does not
    /// come down before Play, and the upload after the session deletes it from the cloud; the copy
    /// of the cloud taken before that upload still holds it.
    func testAnUploadAfterADownloadKeepsACopyOfACloudFileTheMacLacks() throws {
        let (saves, game, location, folder) = try fixture()
        let cloud = try fakeGogdl(for: saves)
        let now = Date()
        let save = folder.appending(path: "slot1/save.dat")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3000)], ofItemAtPath: save.path)
        try write("progress", to: cloud.appending(path: "saves/slot1/save.dat"), at: now.addingTimeInterval(-3000))
        try write("old", to: cloud.appending(path: "saves/old.dat"), at: now.addingTimeInterval(-3000))
        try setLastSync(saves, game, location, now.addingTimeInterval(-2000))

        XCTAssertEqual(saves.sync(game, location: location, folder: folder, direction: .download), .synced)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "old.dat").path), "gogdl brings only newer files")
        try write("more progress", to: save, at: now.addingTimeInterval(600))   // the session
        XCTAssertEqual(saves.sync(game, location: location, folder: folder, direction: .upload), .synced)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.appending(path: "saves/old.dat").path), "gogdl deleted it from the cloud")
        XCTAssertEqual(try String(contentsOf: cloud.appending(path: "saves/slot1/save.dat"), encoding: .utf8), "more progress")
        let copy = try XCTUnwrap(saves.backups(in: saves.backupsFolder(game, location)).first { $0.lastPathComponent.contains("-cloud") })
        XCTAssertEqual(try String(contentsOf: copy.appending(path: "old.dat"), encoding: .utf8), "old")
    }
}
