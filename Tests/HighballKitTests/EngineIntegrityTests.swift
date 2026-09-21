import XCTest
@testable import HighballKit

/// highball#151 and #153: an antivirus emptied part of ~/Library/Application Support/Highball,
/// and every install then died with "exit=53" and Wine's own DLLs "not found". The app offered
/// "try again with a fresh copy" — a download that was never the problem — and both reports took
/// a round of questions to answer by hand.
final class EngineIntegrityTests: XCTestCase {
    /// The log from #153, as it arrived.
    private let output = """
    0024:err:environ:init_peb starting L"Z:\\\\Users\\\\yanhee\\\\SteamSetup.exe" in experimental wow64 mode
    0024:err:module:import_dll Library shcore.dll (which is needed by L"C:\\\\windows\\\\system32\\\\shlwapi.dll") not found
    0024:err:module:import_dll Library shlwapi.dll (which is needed by L"C:\\\\windows\\\\system32\\\\SHELL32.dll") not found
    0024:err:module:import_dll Library SHELL32.dll (which is needed by L"Z:\\\\Users\\\\yanhee\\\\SteamSetup.exe") not found
    0024:err:module:import_dll Library combase.dll (which is needed by L"C:\\\\windows\\\\system32\\\\ole32.dll") not found
    0024:err:module:import_dll Library ole32.dll (which is needed by L"Z:\\\\Users\\\\yanhee\\\\SteamSetup.exe") not found
    0024:err:module:loader_init Importing dlls for L"Z:\\\\Users\\\\yanhee\\\\SteamSetup.exe" failed, status c0000135
    """

    func testNamesAreReadOnceEachAndLowercased() {
        XCTAssertEqual(EngineIntegrity.librariesNotFound(in: output),
                       ["shcore.dll", "shlwapi.dll", "shell32.dll", "combase.dll", "ole32.dll"])
    }

    func testAGameShippingItsOwnMissingDllIsNotTheEngine() throws {
        // Steam's gldriverquery.exe asks for SDL2.dll on every launch and nothing is wrong
        // (highball#156's log carries it while the engine is intact).
        let steam = """
        0348:err:module:import_dll Library SDL2.dll (which is needed by L"C:\\\\Program Files (x86)\\\\Steam\\\\bin\\\\gldriverquery.exe") not found
        """
        let root = try engineTree(shipping: ["ole32.dll", "shell32.dll"])
        XCTAssertEqual(EngineIntegrity.librariesNotFound(in: steam), ["sdl2.dll"])
        XCTAssertEqual(EngineIntegrity.gone(fromEngineAt: root, notFound: EngineIntegrity.librariesNotFound(in: steam)), [])
    }

    func testOnlyWineOwnDllsAbsentFromTheEngineCount() throws {
        let root = try engineTree(shipping: ["ole32.dll", "shell32.dll"])
        // shcore/shlwapi/combase are gone from the engine; ole32 and shell32 are still there,
        // so their "not found" lines are the loader's fallout, not more missing files.
        XCTAssertEqual(EngineIntegrity.gone(fromEngineAt: root, notFound: EngineIntegrity.librariesNotFound(in: output)),
                       ["shcore.dll", "shlwapi.dll", "combase.dll"])
    }

    func testAnIntactEngineReportsNothing() throws {
        let root = try engineTree(shipping: ["shcore.dll", "shlwapi.dll", "shell32.dll", "combase.dll", "ole32.dll"])
        XCTAssertEqual(EngineIntegrity.gone(fromEngineAt: root, notFound: EngineIntegrity.librariesNotFound(in: output)), [])
    }

    func testThe32BitHalfCountsAsShipping() throws {
        let root = try engineTree(shipping: [], shipping32: ["shcore.dll", "shlwapi.dll", "shell32.dll", "combase.dll", "ole32.dll"])
        XCTAssertEqual(EngineIntegrity.gone(fromEngineAt: root, notFound: EngineIntegrity.librariesNotFound(in: output)), [])
    }

    func testTheAlertNamesTheFilesAndOffersTheEngineBack() {
        let r = Recovery.describe(HighballError.engineDamaged(engine: "x64-sikarugir10.0_6-r3",
                                                              files: ["shcore.dll", "shlwapi.dll", "combase.dll"]))
        XCTAssertEqual(r.action, .reinstallEngine("x64-sikarugir10.0_6-r3"))
        XCTAssertTrue(r.meaning.contains("shcore.dll"), r.meaning)
        XCTAssertTrue(r.meaning.contains("exclusions"), r.meaning)
        // Never the old advice: a fresh download of the installer cannot fix an emptied engine.
        XCTAssertFalse(r.meaning.contains("fresh copy"), r.meaning)
    }

    func testListReadsAsASentence() {
        XCTAssertEqual(EngineIntegrity.list(["a.dll"]), "a.dll")
        XCTAssertEqual(EngineIntegrity.list(["a.dll", "b.dll"]), "a.dll and b.dll")
        XCTAssertEqual(EngineIntegrity.list(["a.dll", "b.dll", "c.dll", "d.dll"]), "a.dll, b.dll and 2 more")
    }

    /// An engine tree holding only the DLLs named.
    private func engineTree(shipping: [String], shipping32: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (dir, names) in [("x86_64-windows", shipping), ("i386-windows", shipping32)] {
            let d = root.appending(path: "engine/lib/wine/\(dir)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for name in names { try Data().write(to: d.appending(path: name)) }
        }
        return root
    }
}
