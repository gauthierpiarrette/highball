import XCTest
@testable import HighballKit

/// A `copy` step gives one game a file from the engine (wined3d's d3d9.dll beside csgo.exe, so
/// that game runs on wined3d while the Steam client in the same environment keeps DXMT). It
/// reads only inside the engine, and it is harmless enough to run at Play time.
final class RecipeCopyStepTests: XCTestCase {
    func testDecodesEncodesAndIsHarmless() throws {
        let json = """
        {"id": "csgo-legacy", "kind": "game", "title": "CS:GO", "steps": [
          {"type": "copy", "from": "engine/lib/wine/i386-windows/d3d9.dll", "to": "Program Files (x86)/Steam/steamapps/common/csgo legacy/bin/d3d9.dll", "asNative": true}]}
        """
        let r = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        guard case let .copy(from, to, asNative) = r.steps[0] else { return XCTFail("not a copy step") }
        XCTAssertEqual(from, "engine/lib/wine/i386-windows/d3d9.dll")
        XCTAssertTrue(to.hasSuffix("/bin/d3d9.dll"))
        XCTAssertTrue(asNative)
        XCTAssertTrue(r.isAutoApplicable, "a file copy touches no wine process")
        XCTAssertFalse(r.changesLaunchEnvironment, "the game reads the file when it starts, a running Steam is fine")
        let again = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(r))
        guard case let .copy(_, _, nativeAgain) = again.steps[0], nativeAgain else { return XCTFail("round trip lost the step or the flag") }
    }

    func testAsNativeBlanksTheBuiltinMarkerAndLeavesOtherFilesAlone() {
        var pe = Data(count: 0x80); pe[0] = 0x4D; pe[1] = 0x5A
        pe.replaceSubrange(0x40..<0x51, with: Data("Wine builtin DLL\0".utf8))
        let out = RecipeRunner.withoutBuiltinMarker(pe)
        XCTAssertEqual(out[0x40..<0x51], Data(count: 17))
        XCTAssertEqual(out[0..<2], pe[0..<2])
        let plain = Data("not a dll".utf8)
        XCTAssertEqual(RecipeRunner.withoutBuiltinMarker(plain), plain)
    }

    func testCopySourceStaysInsideTheEngine() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID().uuidString)")
        let dir = root.appending(path: "engine/lib/wine/i386-windows")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appending(path: "d3d9.dll"))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(RecipeRunner.copySource(engineRoot: root, "engine/lib/wine/i386-windows/d3d9.dll"))
        XCTAssertNil(RecipeRunner.copySource(engineRoot: root, "engine/lib/wine/i386-windows/missing.dll"), "must exist")
        XCTAssertNil(RecipeRunner.copySource(engineRoot: root, "engine/lib/wine"), "a directory is not a file")
        XCTAssertNil(RecipeRunner.copySource(engineRoot: root, "../../etc/passwd"), "no climbing out")
        XCTAssertNil(RecipeRunner.copySource(engineRoot: root, "engine/../../outside"), "no climbing out from inside either")
        XCTAssertNil(RecipeRunner.copySource(engineRoot: root, "/etc/passwd"), "no absolute paths")
    }
}
