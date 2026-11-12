import XCTest
@testable import HighballKit

/// A Steam game's session follows its program after it starts itself again with only the file
/// name on the command line, which Wine shows in `ps` without the folder (highball-db#1168).
final class SessionProgramNamesTests: XCTestCase {
    private let civ = GameSession(title: "Civilization IV", bottleName: "Games", appid: 3900,
                                  markers: SessionWatch.markers(installdir: "Sid Meier's Civilization IV Beyond the Sword"))
    private let first = """
          PID   TT  STAT      TIME COMMAND
        70001   ??  S      0:01.00 C:\\Program Files (x86)\\Steam\\steam.exe -silent -applaunch 3900
        70002   ??  S      0:09.00 C:\\Program Files (x86)\\Steam\\steamapps\\common\\Sid Meier's Civilization IV Beyond the Sword\\Beyond the Sword\\Civ4BeyondSword.exe
        """
    // What `ps` showed for a Windows program started again with its bare name (measured with
    // relaunch.exe in a test environment on the Wine 11 engine r31, 2026-11-12).
    private let relaunched = """
          PID   TT  STAT      TIME COMMAND
        70001   ??  S      0:01.00 C:\\Program Files (x86)\\Steam\\steam.exe -silent -applaunch 3900
        70009   ??  S      0:42.00 Civ4BeyondSword.exe -tutorial
        """

    func testTheRelaunchCountsOnceTheNameIsKnown() {
        XCTAssertFalse(SessionWatch.isAlive(civ, ps: relaunched), "the folder markers alone lose it")
        let names = SessionWatch.programNames(civ, ps: first)
        XCTAssertEqual(names, ["civ4beyondsword.exe"])
        XCTAssertTrue(SessionWatch.isAlive(civ, names: names, ps: relaunched))
        XCTAssertFalse(SessionWatch.isAlive(civ, names: names, ps: "  PID TT STAT TIME COMMAND\n70001 ?? S 0:01.00 C:\\Program Files (x86)\\Steam\\steam.exe\n"),
                       "gone once no line runs it")
    }

    func testANameIsMatchedWholeAndWithSpaces() {
        let game = GameSession(title: "G", bottleName: "Games", appid: 1, markers: SessionWatch.markers(installdir: "G"))
        let names = SessionWatch.programNames(game, ps: "1 ?? S 0:00 C:\\Program Files (x86)\\Steam\\steamapps\\common\\G\\Bin\\The Game.exe -x\n")
        XCTAssertEqual(names, ["the game.exe"])
        XCTAssertTrue(SessionWatch.isAlive(game, names: names, ps: "2 ?? S 0:00 \"The Game.exe\" -restart\n"))
        XCTAssertTrue(SessionWatch.isAlive(game, names: ["game.exe"], ps: "2 ?? S 0:00 game.exe\n"))
        XCTAssertFalse(SessionWatch.isAlive(game, names: ["game.exe"], ps: "2 ?? S 0:00 C:\\Other\\mygame.exe\n"), "another program that ends the same way")
    }

    func testExcludedLinesTeachNothing() {
        let bnet = GameSession(title: "D", bottleName: "Games", appid: nil, markers: ["Diablo IV\\"], excluding: ["Launcher.exe"])
        let ps = "1 ?? S 0:00 D:\\Diablo IV\\Diablo IV Launcher.exe --productcode=fenris\n"
        XCTAssertTrue(SessionWatch.programNames(bnet, ps: ps).isEmpty)
        XCTAssertFalse(SessionWatch.isAlive(bnet, names: ["diablo iv launcher.exe"], ps: ps))
    }

    func testAMarkerOnlyInAnArgumentTeachesNothing() {
        let game = GameSession(title: "G", bottleName: "Games", appid: 1, markers: SessionWatch.markers(installdir: "G"))
        XCTAssertTrue(SessionWatch.programNames(game, ps: "1 ?? S 0:00 C:\\windows\\system32\\start.exe /d C:\\Steam\\steamapps\\common\\G\\data\n").isEmpty,
                      "no .exe after the marker, so start.exe is never taken for the game")
    }
}
