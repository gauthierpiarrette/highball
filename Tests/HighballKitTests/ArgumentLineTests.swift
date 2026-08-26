import XCTest
@testable import HighballKit

/// The one-line argument editor behind the per-program settings sheet and
/// `highball pin set <bottle> <pin> args`. Windows paths are full of backslashes,
/// so the split rules must never eat them.
final class ArgumentLineTests: XCTestCase {
    func testBasicSplit() {
        XCTAssertEqual(ArgumentLine.split("-dx11 -skiplauncher"), ["-dx11", "-skiplauncher"])
        XCTAssertEqual(ArgumentLine.split(""), [])
        XCTAssertEqual(ArgumentLine.split("   "), [])
        XCTAssertEqual(ArgumentLine.split("one"), ["one"])
        XCTAssertEqual(ArgumentLine.split("a\tb  c"), ["a", "b", "c"])
    }

    func testQuotedArguments() {
        XCTAssertEqual(ArgumentLine.split(#"-config "C:\my folder\cfg.ini""#),
                       ["-config", #"C:\my folder\cfg.ini"#])
        XCTAssertEqual(ArgumentLine.split(#""two words" plain"#), ["two words", "plain"])
        XCTAssertEqual(ArgumentLine.split(#""""#), [""])   // explicit empty argument
    }

    func testWindowsBackslashesSurvive() {
        // Backslash is only an escape before a quote; bare path separators pass through.
        XCTAssertEqual(ArgumentLine.split(#"C:\Games\thing.exe"#), [#"C:\Games\thing.exe"#])
        XCTAssertEqual(ArgumentLine.split(#"-path C:\a\b\c"#), ["-path", #"C:\a\b\c"#])
    }

    func testEscapedQuote() {
        XCTAssertEqual(ArgumentLine.split(#"say \"hi\""#), ["say", "\"hi\""])
    }

    func testJoinQuotesWhatNeedsIt() {
        XCTAssertEqual(ArgumentLine.join(["-dx11", "two words"]), #"-dx11 "two words""#)
        XCTAssertEqual(ArgumentLine.join([]), "")
        XCTAssertEqual(ArgumentLine.join([""]), #""""#)
    }

    func testRoundTrips() {
        let cases: [[String]] = [
            ["-dx11", "-skiplauncher"],
            ["-config", #"C:\my folder\cfg.ini"#],
            [#"C:\Games\a b\x.exe"#, "--flag"],
            ["quote\"inside", "plain"],
            [],
        ]
        for args in cases {
            XCTAssertEqual(ArgumentLine.split(ArgumentLine.join(args)), args, "round trip failed for \(args)")
        }
    }
}
