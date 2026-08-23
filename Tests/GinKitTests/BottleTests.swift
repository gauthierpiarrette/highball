import XCTest
@testable import HighballKit

final class BottleTests: XCTestCase {
    func testWindowsPathResolution() {
        let b = Bottle(url: URL(fileURLWithPath: "/tmp/b"), settings: BottleSettings(name: "b", engineID: "e"))
        XCTAssertEqual(b.resolve(windowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe").path, "/tmp/b/drive_c/Program Files (x86)/Steam/steam.exe")
        XCTAssertEqual(b.resolve(windowsPath: "windows\\system32\\notepad.exe").path, "/tmp/b/drive_c/windows/system32/notepad.exe")
    }

    func testSettingsRoundTrip() throws {
        var s = BottleSettings(name: "play", engineID: "x64-test")
        s.pins = [Pin(name: "Steam", path: "Program Files (x86)/Steam/steam.exe", renderer: .dxmt)]
        s.environment["FOO"] = "bar"
        let data = try JSONEncoder.gin.encode(s)
        let back = try JSONDecoder.gin.decode(BottleSettings.self, from: data)
        XCTAssertEqual(back.pins.first?.name, "Steam")
        XCTAssertEqual(back.environment["FOO"], "bar")
        XCTAssertEqual(back.renderer, .dxmt)
    }

    func testRecipeDecodes() throws {
        let json = """
        {"id":"t","kind":"launcher","title":"T","steps":[
          {"type":"registry","key":"HKCU\\\\Software\\\\X","name":"Y","valueType":"REG_DWORD","data":"0"},
          {"type":"note","text":"hello"},
          {"type":"renderer","renderer":"d3dmetal"}]}
        """
        let r = try JSONDecoder.gin.decode(Recipe.self, from: Data(json.utf8))
        XCTAssertEqual(r.steps.count, 3)
        if case let .registry(key, _, _, _) = r.steps[0] { XCTAssertEqual(key, "HKCU\\Software\\X") } else { XCTFail() }
    }

    func testManifestDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "spike/engine-manifest.json")
        let m = try EngineManifest.load(from: url)
        XCTAssertEqual(m.arch, "x86_64")
        XCTAssertNotNil(m.licenses?["apple-gptk-license-2023-08-17"])
        XCTAssertEqual(EngineManifest.gatedRenderers["d3dmetal"], "apple-gptk-license-2023-08-17")
        XCTAssertEqual(m.orderedComponents.first?.name, "dxmt")
    }
}
