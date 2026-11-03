import XCTest
@testable import HighballKit

/// GOGSaves against a stand-in for gogdl 1.3.1's save-sync: the same decisions as saves.py
/// (including matching a location's cloud files with `startswith(name)`), over a folder that
/// plays GOG's cloud.
final class GOGFakeGogdlTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appending(path: "home") }
    private var cloud: URL { home.appending(path: "fake-cloud") }
    private let saves = GOGSaves.Location(name: "saves", template: "<?INSTALL?>/saves")
    private let profiles = GOGSaves.Location(name: "saves_profiles", template: "<?INSTALL?>/profiles")

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("needs python3") }
        root = FileManager.default.temporaryDirectory.appending(path: "fake-gogdl-\(UUID().uuidString)")
        let tools = home.appending(path: "tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let gogdl = tools.appending(path: "gogdl")
        try Self.script.write(to: gogdl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gogdl.path)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var store: GOGSaves { GOGSaves(store: GOGStore(paths: HighballPaths(home: home))) }
    private var game: GOGStore.InstalledGame {
        GOGStore.InstalledGame(id: "1", title: "Game", folder: root.appending(path: "Game"), buildID: nil, clientID: nil, dlcIDs: [], tasks: [])
    }

    private func write(_ text: String, to url: URL, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let date = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func folder(_ location: GOGSaves.Location) -> URL { root.appending(path: "Game/\(location.name)") }

    /// `saves` also picks up `saves_profiles/...`, which gogdl fails to download: that failure
    /// belongs to the other location, so the sync still goes through.
    func testAnotherLocationsFilesDoNotFailTheSync() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        try write("profile", to: cloud.appending(path: "saves_profiles/p.dat"))
        let outcome = store.sync(game, location: saves, folder: folder(saves), direction: .download)
        XCTAssertEqual(outcome, .synced)
        XCTAssertEqual(read(folder(saves).appending(path: "slot1.sav")), "cloud save")
        XCTAssertNotNil(store.timestamps()[store.key(game, saves)])
        XCTAssertEqual(store.sync(game, location: profiles, folder: folder(profiles), direction: .download), .synced)
        XCTAssertEqual(read(folder(profiles).appending(path: "p.dat")), "profile")
    }

    /// A file of the location's own that fails to download still fails the sync, also with
    /// another location's failures beside it.
    func testAnOwnFileThatFailsStillFails() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        try write("profile", to: cloud.appending(path: "saves_profiles/p.dat"))
        try "saves/slot1.sav".write(to: home.appending(path: "fake-fail"), atomically: true, encoding: .utf8)
        guard case .failed = store.sync(game, location: saves, folder: folder(saves), direction: .download) else { return XCTFail() }
        XCTAssertNil(store.timestamps()[store.key(game, saves)], "no timestamp kept, so the next sync tries again")
    }

    /// The cloud backup fails when one of the location's own files didn't come down, and no
    /// upload follows.
    func testACloudBackupMissingAFileStopsTheUpload() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        try write("local", to: folder(saves).appending(path: "slot1.sav"))
        try "saves/slot1.sav".write(to: home.appending(path: "fake-fail"), atomically: true, encoding: .utf8)
        guard case let .failed(why) = store.sync(game, location: saves, folder: folder(saves), direction: .upload) else { return XCTFail() }
        XCTAssertTrue(why.contains("backed up"))
        XCTAssertEqual(read(cloud.appending(path: "saves/slot1.sav")), "cloud save", "the cloud is untouched")
    }

    /// An upload deletes cloud files missing on the Mac. Even right after a download, a cloud
    /// file older than the last sync may not have come down, so the cloud is backed up before
    /// every upload.
    func testEveryUploadBacksUpTheCloudFirst() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .download), .synced)
        // An old cloud file the download skipped (older than the last sync), and a new local save.
        try write("old", to: cloud.appending(path: "saves/old.sav"), age: 3600)
        try write("new", to: folder(saves).appending(path: "slot2.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .upload), .synced)
        XCTAssertNil(read(cloud.appending(path: "saves/old.sav")), "gogdl deleted it from the cloud")
        let backup = try XCTUnwrap(store.backups(in: store.backupsFolder(game, saves)).first { $0.lastPathComponent.hasSuffix("-cloud") })
        XCTAssertEqual(read(backup.appending(path: "old.sav")), "old", "but a backup has it")
    }

    /// Another location's newer cloud files make gogdl see a conflict where only the Mac changed:
    /// the upload still goes through, and the download before Play leaves it for the upload.
    func testAnotherLocationsNewerFilesAreNoConflict() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .download), .synced)
        try write("played", to: folder(saves).appending(path: "slot1.sav"))
        try write("profile", to: cloud.appending(path: "saves_profiles/p.dat"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .download), .refused)
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .upload), .synced)
        XCTAssertEqual(read(cloud.appending(path: "saves/slot1.sav")), "played")
        XCTAssertEqual(read(cloud.appending(path: "saves_profiles/p.dat")), "profile", "the other location's file is untouched")
    }

    /// A real conflict (both sides of this location changed) is still asked.
    func testARealConflictIsStillAsked() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .download), .synced)
        try write("played here", to: folder(saves).appending(path: "slot1.sav"))
        try write("played elsewhere", to: cloud.appending(path: "saves/slot2.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .upload), .conflict)
        XCTAssertNil(read(folder(saves).appending(path: "slot2.sav")))
        XCTAssertEqual(read(cloud.appending(path: "saves/slot1.sav")), "cloud save")
    }

    func testTheListingIsReadFromGogdlsDebugLine() {
        let line = #"[SAVES] DEBUG: Files: [{'name': "saves/it's.sav", 'hash': 'abc', 'bytes': 3, 'last_modified': '2024-05-01T10:00:00.250000+00:00'}, {'name': 'saves/\xe9.sav', 'hash': 'def', 'bytes': None}]"#
        let files = GOGSaves.cloudListing(in: line)
        XCTAssertEqual(files?.map(\.name), ["saves/it's.sav", "saves/é.sav"])
        XCTAssertEqual(files?.first?.modified?.timeIntervalSince1970 ?? 0, 1_714_557_600.25, accuracy: 0.001)
        XCTAssertNil(GOGSaves.cloudListing(in: "[SAVES] DEBUG: Files: [{'name': 'broken"))
    }

    /// A deleted file's mark (GOG's hash of nothing) is neither downloaded nor counted.
    func testDeletedMarksAreSkipped() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        try write("", to: cloud.appending(path: "saves/gone.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .download), .synced)
        XCTAssertEqual(read(folder(saves).appending(path: "slot1.sav")), "cloud save")
        XCTAssertNil(read(folder(saves).appending(path: "gone.sav")))
    }

    /// GOG has no cloud storage for the game at all (gogdl gets a 404 and logs no listing): the
    /// first upload has nothing to back up and goes through.
    func testNoCloudStorageAtAll() throws {
        try write("local", to: folder(saves).appending(path: "slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .upload), .synced)
        XCTAssertEqual(read(cloud.appending(path: "saves/slot1.sav")), "local")
        XCTAssertTrue(store.backups(in: store.backupsFolder(game, saves)).isEmpty, "no empty cloud backup")
    }

    /// A location with no files in the cloud (only another location's) makes no cloud backup.
    func testAnEmptyCloudLocationMakesNoBackup() throws {
        try write("profile", to: cloud.appending(path: "saves_profiles/p.dat"))
        try write("local", to: folder(saves).appending(path: "slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .upload), .synced)
        XCTAssertEqual(read(cloud.appending(path: "saves/slot1.sav")), "local")
        XCTAssertTrue(store.backups(in: store.backupsFolder(game, saves)).isEmpty)
    }

    /// An unchanged cloud is not backed up again: the listing matches the newest cloud backup.
    func testAnUnchangedCloudIsBackedUpOnce() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .download), .synced)
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .upload), .synced)
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .upload), .synced)
        let cloudBackups = store.backups(in: store.backupsFolder(game, saves)).filter { GOGSaves.kind(of: $0) == .cloud }
        XCTAssertEqual(cloudBackups.count, 1)
    }

    /// Picking "Keep this Mac's saves" after an upload conflict keeps the cloud backup the
    /// conflicting upload made, without downloading the cloud a second time.
    func testKeepingTheMacsSavesKeepsTheCloudBackupForGood() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .download), .synced)
        try write("played here", to: folder(saves).appending(path: "slot1.sav"))
        try write("played elsewhere", to: cloud.appending(path: "saves/slot2.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .upload), .conflict)
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .forceUpload, keepBackups: true), .synced)
        let cloudBackups = store.backups(in: store.backupsFolder(game, saves)).filter { GOGSaves.kind(of: $0) == .cloud }
        XCTAssertEqual(cloudBackups.count, 1)
        XCTAssertTrue(cloudBackups.allSatisfy(GOGSaves.isKept))
        XCTAssertEqual(read(cloudBackups[0].appending(path: "slot2.sav")), "played elsewhere")
        XCTAssertEqual(read(cloud.appending(path: "saves/slot1.sav")), "played here")
    }

    /// A refusal leaves the last sync's timestamp: gogdl prints back the one it was given.
    func testARefusalKeepsTheLastTimestamp() throws {
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .download), .synced)
        let before = store.timestamps()[store.key(game, saves)]
        try write("played", to: folder(saves).appending(path: "slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: folder(saves), direction: .download), .refused)
        XCTAssertEqual(store.timestamps()[store.key(game, saves)], before)
    }

    /// Dates with no offset are local time, as Python reads them.
    func testAnotherLocationsNewerFilesWithLocalDates() throws {
        try Data().write(to: home.appending(path: "fake-naive-dates"))
        try testAnotherLocationsNewerFilesAreNoConflict()
    }

    /// Debug lines quote paths and arguments: a phrase in one is not read as gogdl's result.
    func testDebugLinesAreNotReadAsResults() throws {
        let odd = root.appending(path: "Files in conflict Downloading file failed/saves")
        try write("cloud save", to: cloud.appending(path: "saves/slot1.sav"))
        XCTAssertEqual(store.sync(game, location: saves, folder: odd, direction: .download), .synced)
        XCTAssertEqual(read(odd.appending(path: "slot1.sav")), "cloud save")
    }

    /// gogdl 1.3.1's save-sync, cut down to what decides what moves (saves.py), with the log
    /// lines it prints around that.
    static let script = #"""
    #!/usr/bin/python3
    import os, sys, shutil, hashlib, datetime
    home = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cloud_root = os.path.join(home, "fake-cloud")
    naive = os.path.exists(os.path.join(home, "fake-naive-dates"))
    DELETED = "aadd86936a80ee8a369579c3926f1b3c"
    try:
        failing = set(open(os.path.join(home, "fake-fail")).read().split())
    except OSError:
        failing = set()
    a = sys.argv[1:]
    debug = "--debug" in a
    a = a[a.index("save-sync") + 1:]
    path, raw_ts, name = a[0], a[a.index("--ts") + 1], a[a.index("--name") + 1]
    ts = float(raw_ts)
    pref = {"--skip-upload": "download", "--skip-download": "upload", "--force-upload": "forceupload", "--force-download": "forcedownload"}
    prefered = next((pref[x] for x in a if x in pref), None)
    def log(who, level, msg): sys.stderr.write(f"[{who}] {level}: {msg}\n"); sys.stderr.flush()
    def info(msg): log("SAVES", "INFO", msg)
    def warn(msg): log("SAVES", "WARNING", msg)
    def iso(t):
        if naive: return datetime.datetime.fromtimestamp(t).isoformat()
        return datetime.datetime.fromtimestamp(t, tz=datetime.timezone.utc).isoformat()
    if debug: log("MAIN", "DEBUG", f"Namespace(path={path!r}, dirname={name!r}, timestamp={raw_ts!r})")
    os.makedirs(path, exist_ok=True)
    local = []
    for d, _, fs in os.walk(path):
        for f in fs:
            p = os.path.join(d, f); local.append((os.path.relpath(p, path), p, os.stat(p).st_mtime))
    if not local: info("No files in directory")
    info(f"Local files: {len(local)}")
    if debug: log("urllib3.connectionpool", "DEBUG", "https://cloudstorage.gog.com:443 \"GET /v1/0/0 HTTP/1.1\" 200 None")
    listing = []
    for d, _, fs in os.walk(cloud_root):
        for f in fs:
            p = os.path.join(d, f); data = open(p, "rb").read()
            listing.append({"name": os.path.relpath(p, cloud_root), "hash": DELETED if not data else hashlib.md5(data).hexdigest(),
                            "bytes": len(data), "last_modified": iso(os.stat(p).st_mtime)})
    if listing:   # an empty client is a 404, which gogdl answers with [] before logging anything
        info(f"Files in cloud: {len(listing)}")
        if debug: log("SAVES", "DEBUG", f"Files: {listing}")
    cloud = []
    for e in listing:
        if e["name"].startswith(name):
            rel = e["name"].replace(f"{name}/", "", 1)
            cloud.append((rel, os.path.join(path, rel), datetime.datetime.fromisoformat(e["last_modified"]).astimezone().timestamp(), e["hash"]))
    downloadable = [f for f in cloud if f[3] != DELETED]
    def download(f):
        src = os.path.join(cloud_root, name, f[0])
        if not os.path.exists(src) or f"{name}/{f[0]}" in failing:
            log("SAVES", "ERROR", "Downloading file failed"); return
        os.makedirs(os.path.dirname(f[1]), exist_ok=True); shutil.copy2(src, f[1])
    def upload(f):
        dst = os.path.join(cloud_root, name, f[0]); os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copyfile(f[1], dst)
    def delete(f):
        p = os.path.join(cloud_root, name, f[0])
        if os.path.exists(p): os.remove(p)
    def done():
        sys.stdout.write(str(datetime.datetime.now().timestamp())); sys.stdout.flush(); info("Done"); sys.exit(0)
    if local and not cloud:
        info("No files in cloud, uploading"); [upload(f) for f in local]; info("Done")
        sys.stdout.write(str(datetime.datetime.now().timestamp())); sys.exit(0)
    if not local and cloud:
        info("No files locally, downloading"); [download(f) for f in downloadable]; info("Done")
        sys.stdout.write(str(datetime.datetime.now().timestamp())); sys.exit(0)
    lp, cp = [f[0] for f in local], [f[0] for f in cloud]
    updated_local = [f for f in local if f[2] > ts]
    updated_cloud = [f for f in cloud if f[3] != DELETED and f[2] > ts]
    not_remote = [f for f in local if f[0] not in cp]
    not_local = [f for f in cloud if f[3] != DELETED and f[0] not in lp]
    if not updated_local and updated_cloud: action = "download"
    elif updated_local and not updated_cloud: action = "upload"
    elif not updated_local and not updated_cloud: action = "none"
    else: action = "conflict"
    if prefered == "forceupload": warn("Forcing upload"); updated_local = local; action = "upload"
    elif prefered == "forcedownload": warn("Forcing download"); updated_cloud = downloadable; action = "download"
    if prefered == "upload" and action == "download": warn("Refused to upload files, newer files in the cloud"); print(raw_ts); sys.exit(0)
    if prefered == "download" and action == "upload": warn("Refused to download files, newer files locally"); print(raw_ts); sys.exit(0)
    if action == "upload":
        info("Uploading files"); [upload(f) for f in updated_local]
        for f in not_local: info(f"DELETING IN CLOUD {f[0]}"); delete(f)
    elif action == "download":
        info("Downloading files"); [download(f) for f in updated_cloud]
        for f in not_remote: info(f"DELETING LOCALLY {f[1]}"); os.remove(f[1])
    elif action == "conflict":
        warn("Files in conflict force downloading or uploading of files")
    elif action == "none":
        info("Nothing to do")
    done()
    """#
}
