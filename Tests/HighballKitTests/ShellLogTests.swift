import XCTest
@testable import HighballKit

/// A long tool has to leave a file behind. Three reports of the core fonts failing (highball#135,
/// #180, #183) could not be answered because the winetricks step wrote nothing anywhere: what it
/// said lived only in the error dialog, and the newest file in the logs folder, the one a report
/// attaches, was the game's launch log.
final class ShellLogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "shell-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTheLogCarriesTheHeaderTheOutputAndTheExitCode() throws {
        let log = dir.appending(path: "run.log")
        let text = try Shell.capture("/bin/echo", ["hello"], log: log, logHeader: "# highball winetricks corefonts bottle=Games")
        XCTAssertEqual(text, "hello\n", "the caller still gets what it always got")
        let written = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("# highball winetricks corefonts bottle=Games\n# /bin/echo hello\n"), written)
        XCTAssertTrue(written.contains("\nhello\n"), written)
        XCTAssertTrue(written.contains("# exit=0 after "), "a finished step is told from a failed one by the footer")
    }

    func testAFailedStepStillLeavesItsOutputAndCode() throws {
        let log = dir.appending(path: "fail.log")
        XCTAssertThrowsError(try Shell.capture("/bin/sh", ["-c", "echo broke; exit 3"], log: log)) { error in
            guard case let HighballError.processFailed(_, status, output) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 3)
            XCTAssertEqual(output, "broke\n", "Recovery reads the reason out of this")
        }
        let written = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(written.contains("broke"), written)
        XCTAssertTrue(written.contains("# exit=3 after "), written)
    }

    func testWithoutALogNothingIsWrittenAndTheOutputIsUnchanged() throws {
        XCTAssertEqual(try Shell.capture("/bin/echo", ["quiet"]), "quiet\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// The output arrives as it is produced, so a step that never finishes still leaves what it
    /// managed to say. dotnet48 runs for forty minutes and looks idle for most of them.
    func testOutputIsStreamedRatherThanKeptForTheEnd() throws {
        let log = dir.appending(path: "stream.log")
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            let seen = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            XCTAssertTrue(seen.contains("first"), "nothing was written while the tool was still running: \(seen)")
            XCTAssertFalse(seen.contains("# exit="), "the footer arrives at the end, not before")
        }
        _ = try Shell.capture("/bin/sh", ["-c", "echo first; sleep 1; echo second"], log: log)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.9)
        let written = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(written.contains("first") && written.contains("second") && written.contains("# exit=0"), written)
    }

    func testTheLogNameSaysWhichStepItWas() {
        let name = WineRunner.uniqueLogURL(in: dir, named: "2026-09-22T101500Z-Games-winetricks-corefonts").lastPathComponent
        XCTAssertEqual(name, "2026-09-22T101500Z-Games-winetricks-corefonts.log",
                       "a report picks the newest log by name, so the verb has to be in it")
    }
}
