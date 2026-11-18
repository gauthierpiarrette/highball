import XCTest
@testable import HighballKit

/// An engine can ask for registry values under HKCU\Software\Wine\AppDefaults\<exe>
/// (`EngineManifest.appDefaults`), mirrored into the prefix before a launch. First use: the Wine
/// 11 tree's Steam browser drawing black in the DXVK mode (highball#202).
final class EngineAppDefaultsTests: XCTestCase {

    func testMarkerIsStableAcrossDictionaryOrder() {
        let a = WineRunner.appDefaultsMarker(engineID: "e", defaults: ["steamwebhelper.exe": ["CommandLineAppend": "--disable-gpu", "Other": "x"], "a.exe": ["K": "v"]])
        let b = WineRunner.appDefaultsMarker(engineID: "e", defaults: ["a.exe": ["K": "v"], "steamwebhelper.exe": ["Other": "x", "CommandLineAppend": "--disable-gpu"]])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "e:a.exe{K=v},steamwebhelper.exe{CommandLineAppend=--disable-gpu;Other=x}")
        XCTAssertNotEqual(a, WineRunner.appDefaultsMarker(engineID: "f", defaults: ["a.exe": ["K": "v"]]), "a different engine rewrites")
        XCTAssertEqual(WineRunner.appDefaultsMarker(engineID: "e", defaults: [:]), "e:")
    }

    func testManifestRoundTripsTheDefaults() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        var m = try EngineManifest.load(from: manifestURL)
        XCTAssertNil(m.appDefaults)
        m.appDefaults = ["steamwebhelper.exe": ["CommandLineAppend": "--disable-gpu"]]
        let dir = FileManager.default.temporaryDirectory.appending(path: "hb-appdefaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try m.save(to: dir.appending(path: "manifest.json"))
        XCTAssertEqual(try EngineManifest.load(from: dir.appending(path: "manifest.json")).appDefaults, m.appDefaults)
    }

    func testInstalledEnginesAdoptTheDefaultsFromKnownManifests() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-appdefaults-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = HighballPaths(home: home)
        let store = EngineStore(paths: paths)
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engine-manifest.json")
        var base = try EngineManifest.load(from: manifestURL)
        base.appDefaults = nil
        for id in ["x64-crossover26.3-r12", "x64-sikarugir10.0_6-r7"] {
            var m = base; m.id = id
            let dir = paths.engine(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try m.save(to: dir.appending(path: "manifest.json"))
        }
        var known = base; known.id = "x64-crossover26.3-r12"; known.appDefaults = ["steamwebhelper.exe": ["CommandLineAppend": "--disable-gpu"]]
        XCTAssertEqual(store.adoptKnownFacts(known: [known]), ["x64-crossover26.3-r12"])
        XCTAssertEqual(try store.engine("x64-crossover26.3-r12").manifest.appDefaults, known.appDefaults)
        XCTAssertNil(try store.engine("x64-sikarugir10.0_6-r7").manifest.appDefaults)
        XCTAssertEqual(store.adoptKnownFacts(known: [known]), [], "a second pass changes nothing")
    }

    func testSteamsBrowserDrawsInItsOwnProcess() {
        XCTAssertEqual(WineRunner.appDefaults(engine: [:]), ["steamwebhelper.exe": ["CommandLineAppend": "--in-process-gpu"]])
        XCTAssertEqual(WineRunner.appDefaults(engine: ["steamwebhelper.exe": ["CommandLineAppend": "--disable-gpu"], "a.exe": ["K": "v"]]),
                       ["steamwebhelper.exe": ["CommandLineAppend": "--disable-gpu --in-process-gpu"], "a.exe": ["K": "v"]])
    }

    func testSettingsKeepTheSyncMarker() throws {
        var s = BottleSettings(name: "t", engineID: "e")
        s.engineAppDefaultsSynced = "e:steamwebhelper.exe{CommandLineAppend=--disable-gpu}"
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(BottleSettings.self, from: data).engineAppDefaultsSynced, s.engineAppDefaultsSynced)
    }
}
