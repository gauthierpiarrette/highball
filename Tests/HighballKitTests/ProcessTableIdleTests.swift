import XCTest
@testable import HighballKit

final class ProcessTableIdleTests: XCTestCase {
    private let prefix = "/Users/me/Library/Application Support/Highball/bottles/games"
    private let server = "/private/tmp/.wine-501/server-100000f-1db1d89"

    func testWinePlumbingAndServicesAreIdle() {
        // services.exe, winedevice, plugplay, rpcss, svchost work in drive_c/windows, explorer in
        // system32, a Windows service (RockstarService.exe) in drive_c/windows too (measured).
        let cwds = [server, prefix + "/drive_c/windows", prefix + "/drive_c/windows",
                    prefix + "/drive_c/windows/system32", prefix + "/drive_c/windows"]
        XCTAssertTrue(ProcessTable.isIdle(workingDirectories: cwds, prefix: prefix, serverDirectory: server))
    }

    func testNoProcessesIsIdle() {
        XCTAssertTrue(ProcessTable.isIdle(workingDirectories: [], prefix: prefix, serverDirectory: server))
    }

    func testAProgramInItsOwnFolderIsNotIdle() {
        let cwds = [server, prefix + "/drive_c/windows", prefix + "/drive_c/Program Files/Rockstar Games/Launcher"]
        XCTAssertFalse(ProcessTable.isIdle(workingDirectories: cwds, prefix: prefix, serverDirectory: server))
    }

    func testASteamClientIsNotIdle() {
        let cwds = [server, prefix + "/drive_c/windows", prefix + "/drive_c/Program Files (x86)/Steam"]
        XCTAssertFalse(ProcessTable.isIdle(workingDirectories: cwds, prefix: prefix, serverDirectory: server))
    }

    func testAFolderNamedLikeWindowsOutsideItIsNotIdle() {
        // "drive_c/windowsgame" must not pass as "drive_c/windows".
        let cwds = [prefix + "/drive_c/windowsgame"]
        XCTAssertFalse(ProcessTable.isIdle(workingDirectories: cwds, prefix: prefix, serverDirectory: server))
    }

    func testServerWithoutDirectoryStillClassifies() {
        XCTAssertTrue(ProcessTable.isIdle(workingDirectories: [prefix + "/drive_c/windows"], prefix: prefix, serverDirectory: nil))
        XCTAssertFalse(ProcessTable.isIdle(workingDirectories: [server], prefix: prefix, serverDirectory: nil))
    }
}

final class ProcessTablePlumbingTests: XCTestCase {
    private let prefix = "/Users/me/Library/Application Support/Highball/bottles/games"

    func testWindowsSystemProcessesArePlumbing() {
        XCTAssertTrue(ProcessTable.isPlumbing(executable: "C:\\windows\\system32\\services.exe", workingDirectory: prefix + "/drive_c/windows", prefix: prefix))
        XCTAssertTrue(ProcessTable.isPlumbing(executable: "C:\\windows\\system32\\explorer.exe", workingDirectory: prefix + "/drive_c/windows/system32", prefix: prefix))
    }

    func testTheServerIsPlumbingWhereverItWorks() {
        XCTAssertTrue(ProcessTable.isPlumbing(executable: "/e/engine/bin/wineserver", workingDirectory: "/private/tmp/.wine-501/server-1-2", prefix: prefix))
    }

    func testAWindowsServiceCountsAsPlumbingByItsWorkingDirectory() {
        // Rockstar's service is started by services.exe in drive_c/windows (measured 2026-09-18).
        XCTAssertTrue(ProcessTable.isPlumbing(executable: "C:\\Program Files\\Rockstar Games\\Launcher\\RockstarService.exe", workingDirectory: prefix + "/drive_c/windows", prefix: prefix))
    }

    func testAProgramInItsOwnFolderIsNotPlumbing() {
        XCTAssertFalse(ProcessTable.isPlumbing(executable: "C:\\Program Files (x86)\\Steam\\steam.exe", workingDirectory: prefix + "/drive_c/Program Files (x86)/Steam", prefix: prefix))
        XCTAssertFalse(ProcessTable.isPlumbing(executable: "C:/ProgramData/Battle.net/Agent/Agent.exe", workingDirectory: prefix + "/drive_c/ProgramData/Battle.net/Agent", prefix: prefix))
    }
}

final class PinOwnershipTests: XCTestCase {
    private let steam = Pin(name: "Steam", path: "Program Files (x86)/Steam/steam.exe", arguments: [], environment: ["WINEMSYNC": "0", "WINEESYNC": "0"], renderer: nil)
    private let rockstar = Pin(name: "Rockstar Launcher", path: "Program Files/Rockstar Games/Launcher/Launcher.exe", arguments: [], environment: [:], renderer: .dxvk)

    func testAHelperUnderThePinnedFolderBelongsToThePin() {
        XCTAssertEqual(Bottle.pin(owning: "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win7x64\\steamwebhelper.exe", in: [steam, rockstar])?.name, "Steam")
        XCTAssertEqual(Bottle.pin(owning: "C:\\Program Files (x86)\\Steam\\steam.exe", in: [steam, rockstar])?.name, "Steam")
    }

    func testAProgramElsewhereBelongsToNoPin() {
        XCTAssertNil(Bottle.pin(owning: "C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe", in: [steam]))
        XCTAssertNil(Bottle.pin(owning: "C:\\windows\\system32\\services.exe", in: [steam, rockstar]))
    }

    func testForwardSlashesAndCaseDoNotMatter() {
        XCTAssertEqual(Bottle.pin(owning: "c:/program files/rockstar games/launcher/RockstarService.exe", in: [steam, rockstar])?.name, "Rockstar Launcher")
    }
}
