import XCTest
@testable import HighballKit

/// A steam.exe left empty or truncated by an interrupted self-update is not an install
/// (highball#245): the Steam row must offer the installer, not Open Steam, and the crash alert
/// must not propose a graphics mode for it.
final class PEExecutableTests: XCTestCase {
    private func temp(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pe-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    /// The smallest file that walks like a PE: an MZ header whose e_lfanew (0x3c) points at "PE\0\0".
    private func minimalPE() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 0x100)
        b[0] = 0x4D; b[1] = 0x5A
        b[0x3c] = 0x80
        b[0x80] = 0x50; b[0x81] = 0x45; b[0x82] = 0; b[0x83] = 0
        return b
    }

    func testAnEmptyFileIsNotAnExecutable() throws {
        XCTAssertFalse(PEExportName.isWindowsExecutable(at: try temp("steam.exe", [])))
    }

    func testAFileCutShortAfterTheHeaderIsNotAnExecutable() throws {
        XCTAssertFalse(PEExportName.isWindowsExecutable(at: try temp("steam.exe", Array(minimalPE()[0..<0x40]))))
    }

    func testTextIsNotAnExecutable() throws {
        XCTAssertFalse(PEExportName.isWindowsExecutable(at: try temp("steam.exe", Array("not a program".utf8))))
    }

    func testAMinimalPEIsAnExecutable() throws {
        XCTAssertTrue(PEExportName.isWindowsExecutable(at: try temp("steam.exe", minimalPE())))
    }

    func testAMissingFileIsNotAnExecutable() {
        XCTAssertFalse(PEExportName.isWindowsExecutable(at: URL(fileURLWithPath: "/nonexistent/steam.exe")))
    }
}
