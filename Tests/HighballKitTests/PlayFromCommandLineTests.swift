import XCTest
@testable import HighballKit

/// Starting a library game from the command line (highball#432): `highball play` takes the ids
/// `highball library` lists and library.json keys everything by, hands them to the app as the
/// play link a game's Mac app opens, and with --wait follows the app's running games.
final class PlayFromCommandLineTests: XCTestCase {
    func testEveryLibraryIdNamesTheTargetItsLinkStarts() {
        let uuid = UUID(uuidString: "B43215E4-3490-4E8A-835B-3668A02B279F")!
        let targets: [PlayLink.Target] = [.steam(appid: 2420510), .epic(appName: "Fortnite"), .gog(id: "1207658924"),
                                          .pin(bottle: "Games", id: uuid), .battlenet(product: "wow_classic"),
                                          .launcher(id: "ea-app")]
        for target in targets {
            XCTAssertEqual(PlayLink.Target(libraryID: target.libraryID), target, target.libraryID)
        }
        XCTAssertEqual(PlayLink.Target(libraryID: "steam:620")?.libraryID, "steam:620")
        // A Battle.net game's link is the one its Mac app would open (highball#417, #432).
        let link = PlayLink.url(for: .battlenet(product: "pro"), token: "t")
        XCTAssertEqual(link.absoluteString, "highball://play/battlenet/pro?t=t")
        XCTAssertEqual(PlayLink.parse(link)?.target, .battlenet(product: "pro"))
    }

    /// An environment's name may hold a colon or a space; the program's id ends at its uuid.
    func testAProgramIdKeepsItsEnvironmentsWholeName() {
        let uuid = UUID(uuidString: "B43215E4-3490-4E8A-835B-3668A02B279F")!
        XCTAssertEqual(PlayLink.Target(libraryID: "pin:Old games: 1998:\(uuid.uuidString)"), .pin(bottle: "Old games: 1998", id: uuid))
        // A lowercase uuid typed by hand names the same program.
        XCTAssertEqual(PlayLink.Target(libraryID: "pin:Games:\(uuid.uuidString.lowercased())")?.libraryID, "pin:Games:\(uuid.uuidString)")
        // And its link is the one the Mac app for it would open.
        let url = PlayLink.url(for: .pin(bottle: "Old games", id: uuid), token: "t")
        XCTAssertEqual(PlayLink.parse(url)?.target, .pin(bottle: "Old games", id: uuid))
    }

    func testAnythingElseIsNotAnId() {
        for bad in ["", "steam", "steam:", "steam:0", "steam:-3", "steam:abc", "epic:", "pin:Games",
                    "pin::B43215E4-3490-4E8A-835B-3668A02B279F", "pin:Games:not-a-uuid", "gog:", "gog:abc",
                    "launcher:Steam Client", "launcher:../x", "2420510", "battlenet:", "battlenet:../wow", "battlenet:wow classic"] {
            XCTAssertNil(PlayLink.Target(libraryID: bad), bad)
        }
    }

    func testTheListingLeadsWithTheIdAndStaysOneLinePerGame() {
        let mac = HighballKit.LibraryItem(source: .steam, id: "steam:400", title: "Portal", bottleName: "Games",
                                          installed: false, installedOnMac: true, steamAppID: 400)
        XCTAssertEqual(LibraryListing.line(LibraryListing.entry(mac, title: "Portal")), "steam:400\tPortal\tGames\tinstalled on Mac")
        let epic = HighballKit.LibraryItem(source: .epic, id: "epic:Duck", title: "Cardpocalypse", bottleName: nil,
                                           installed: false, epicAppName: "Duck")
        XCTAssertEqual(LibraryListing.line(LibraryListing.entry(epic, title: "Card\tpocalypse\n")), "epic:Duck\tCard pocalypse \t-\tnot installed")
        let game = HighballKit.LibraryItem(source: .steam, id: "steam:620", title: "Portal 2", bottleName: "Games", installed: true)
        XCTAssertEqual(LibraryListing.line(LibraryListing.entry(game, title: "Portal Deux")), "steam:620\tPortal Deux\tGames\tinstalled")
    }

    func testRunningGamesRoundTripAndAGoneAppReadsAsNothingKnown() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-running-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = HighballPaths(home: home)
        XCTAssertNil(RunningGames.current(paths: paths), "no file, no app")
        RunningGames.write(["steam:620", "epic:Duck"], paths: paths)
        XCTAssertEqual(RunningGames.read(paths: paths)?.pid, getpid())
        XCTAssertEqual(RunningGames.current(paths: paths, isLive: { _ in true }), ["steam:620", "epic:Duck"])
        XCTAssertNil(RunningGames.current(paths: paths, isLive: { _ in false }))
        // The writer here is this test process, which is alive and is the program it wrote down.
        XCTAssertEqual(RunningGames.current(paths: paths), ["steam:620", "epic:Duck"])
        RunningGames.write([], paths: paths)
        XCTAssertEqual(RunningGames.current(paths: paths), [])
    }

    func testOnlyALiveProcessRunningTheSameProgramCounts() throws {
        let me = Bundle.main.executableURL!.resolvingSymlinksInPath().path
        XCTAssertTrue(RunningGames.isLive(RunningGames(pid: getpid(), executable: me, games: [])))
        XCTAssertFalse(RunningGames.isLive(RunningGames(pid: getpid(), executable: "/Applications/Other.app/Contents/MacOS/Other", games: [])),
                       "a process id reused by another program")
        XCTAssertFalse(RunningGames.isLive(RunningGames(pid: 0, executable: me, games: [])))
        let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run(); gone.waitUntilExit()
        XCTAssertFalse(RunningGames.isLive(RunningGames(pid: gone.processIdentifier, executable: "/usr/bin/true", games: [])))
    }

    func testTheWaitFollowsTheGameFromStartToQuit() {
        let id = "steam:620"
        // Not listed yet: keep waiting for the start, until the start timeout.
        XCTAssertEqual(PlayWait.step(.starting, id: id, running: nil, waited: 5, startTimeout: 600), .keepWaiting(.starting))
        XCTAssertEqual(PlayWait.step(.starting, id: id, running: ["steam:730"], waited: 5, startTimeout: 600), .keepWaiting(.starting))
        XCTAssertEqual(PlayWait.step(.starting, id: id, running: [], waited: 600, startTimeout: 600), .neverStarted)
        // Listed: running, whatever the time.
        XCTAssertEqual(PlayWait.step(.starting, id: id, running: [id], waited: 900, startTimeout: 600), .keepWaiting(.running))
        XCTAssertEqual(PlayWait.step(.running, id: id, running: [id, "steam:730"], waited: 7200, startTimeout: 600), .keepWaiting(.running))
        // Gone from the list, or the app quit: the game has ended.
        XCTAssertEqual(PlayWait.step(.running, id: id, running: ["steam:730"], waited: 7200, startTimeout: 600), .ended)
        XCTAssertEqual(PlayWait.step(.running, id: id, running: nil, waited: 7200, startTimeout: 600), .ended)
    }
}
