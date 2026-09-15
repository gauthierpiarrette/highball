import XCTest
@testable import HighballKit

final class EpicStoreTests: XCTestCase {
    /// Legendary has no terminal under Highball: the selective-download prompt (optional
    /// language packs) raised EOFError and killed the install (#110). `-y` alone does not skip it.
    func testInstallAnswersEveryPromptOnTheCommandLine() {
        let args = EpicStore.installArguments(appName: "Phoenix", basePath: "/c/Games")
        XCTAssertTrue(args.contains("-y"))
        XCTAssertTrue(args.contains("--skip-sdl"))
        XCTAssertEqual(Array(args.prefix(2)), ["install", "Phoenix"])
        XCTAssertEqual(args[args.firstIndex(of: "--base-path")! + 1], "/c/Games")
    }
}
