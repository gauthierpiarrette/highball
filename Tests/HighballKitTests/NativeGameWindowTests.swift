import Foundation
import XCTest
@testable import HighballKit

final class NativeGameWindowTests: XCTestCase {
    func testWindowModeOnlyReadsTheGameMacDriverKey() {
        let reg = #"""
        [Software\\Wine\\Mac Driver] 1
        "NativeGameWindow"="free"
        [Software\\Wine\\AppDefaults\\Bloody Hell.exe\\Mac Driver] 1
        "NativeGameWindow"="free"
        [Software\\Wine\\AppDefaults\\Other.exe\\Mac Driver] 1
        "NativeGameWindow"="y"
        [Software\\Wine\\AppDefaults\\Reset.exe\\Mac Driver] 1
        "NativeGameWindow"="n"
        """#
        for (file, mode): (String, NativeGameWindow) in [
            ("bloody hell.exe", .freeCursor), ("Other.exe", .native),
            ("Reset.exe", .standard), ("Unconfigured.exe", .standard)
        ] {
            let exe = URL(fileURLWithPath: "/games/" + file)
            XCTAssertEqual(NativeGameWindow.read(userReg: reg, executable: exe), mode)
        }
    }
}
