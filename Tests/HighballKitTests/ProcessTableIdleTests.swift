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
