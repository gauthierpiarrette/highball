import XCTest
@testable import HighballKit

/// highball#76: a component whose `into` named the existing `engine` directory replaced the
/// whole Wine tree (removeItem then moveItem) and the install still said "installed". A
/// directory component may create its target, never take over one another component filled.
final class EngineExtractTests: XCTestCase {
    func testADirectoryComponentMayNotReplaceAFilledDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = root.appending(path: "engine")
        try FileManager.default.createDirectory(at: engine.appending(path: "bin"), withIntermediateDirectories: true)
        try Data("wine".utf8).write(to: engine.appending(path: "bin/wine"))
        XCTAssertNotNil(EngineStore.directoryCollision(at: engine, sourceIsDirectory: true), "a filled directory is not replaced")
        XCTAssertNil(EngineStore.directoryCollision(at: root.appending(path: "renderers/dxmt/wine"), sourceIsDirectory: true), "a new directory is fine")
        XCTAssertNil(EngineStore.directoryCollision(at: engine.appending(path: "bin/wine"), sourceIsDirectory: false), "a single file may replace a file (the MoltenVK override)")
        let empty = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(EngineStore.directoryCollision(at: empty, sourceIsDirectory: true), "an empty directory is just a placeholder")
    }
}
