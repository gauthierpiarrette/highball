import XCTest
@testable import HighballKit

final class SessionMarkersTests: XCTestCase {
    func testExecutableMarkerIsTheFileName() {
        let m = SessionWatch.markers(executable: URL(fileURLWithPath: "/b/drive_c/Games/Warframe/Tools/Launcher.exe"))
        XCTAssertEqual(m, ["Launcher.exe"])
        let ps = #"  123 ?? 0:01.00 C:\Games\Warframe\Tools\Launcher.exe -cluster:public"#
        XCTAssertTrue(SessionWatch.isAlive(markers: m, ps: ps))
        XCTAssertFalse(SessionWatch.isAlive(markers: m, ps: "  9 ?? 0:00.10 C:\\windows\\system32\\services.exe"))
    }
}
