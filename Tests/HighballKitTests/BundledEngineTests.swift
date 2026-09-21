import XCTest
@testable import HighballKit

/// Every engine manifest the app bundles must decode, and the ones with a purpose beyond the
/// default must carry the settings that purpose rests on: r6 exists to offer D3DMetal from
/// GPTK 4 on macOS 27 with its Metal 4 backend off (highball#85), and a manifest that lost any
/// of that would ship silently, since nothing else reads those fields before a user picks it.
final class BundledEngineTests: XCTestCase {
    private var engines: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "spike/engines")
    }

    private func manifests() throws -> [EngineManifest] {
        let files = try FileManager.default.contentsOfDirectory(at: engines, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty, "no bundled manifests under spike/engines")
        return try files.map { try EngineManifest.load(from: $0) }
    }

    func testEveryBundledManifestDecodesWithAUniqueIdAndAFloor() throws {
        let all = try manifests()
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "duplicate engine ids among the bundled manifests")
        for m in all {
            XCTAssertFalse(m.minMacOS.isEmpty, "\(m.id) has no minMacOS")
            XCTAssertTrue(m.runs(onMacOS: "99.0"), "\(m.id): a floor nothing satisfies")
        }
    }

    func testR6CarriesGPTK4D3DMetalOnMacOS27WithTheMetal4BackendOff() throws {
        let r6 = try XCTUnwrap(try manifests().first { $0.id == "x64-sikarugir10.0_6-r6" }, "r6 manifest missing")
        XCTAssertEqual(r6.minMacOS, "27.0")
        XCTAssertFalse(r6.runs(onMacOS: "26.6.2"), "r6 was measured on 27 only and must not be offered below it")
        XCTAssertEqual(r6.baseEnv?["D3DM_MTL4"], "0", "the Metal 4 backend ends UE5 titles within a minute on 4.0b2")
        let d3dmetal = try XCTUnwrap(r6.components["d3dmetal"], "r6 has no d3dmetal component")
        XCTAssertEqual(d3dmetal.sha256, "96cbbe89b71cb07cc33bd761ae4b79452b9cdf3198593dfb779036caf85f07a9")
        XCTAssertEqual(d3dmetal.extract?.into, "renderers/d3dmetal", "rendererDir prefers the engine's own renderers/d3dmetal")
        XCTAssertEqual(d3dmetal.license, "apple-gptk-license-2023-08-17", "same licence text as GPTK 3, same gate")
    }

    /// The lsfg variant is r6 with one component added, so it has to keep everything r6 exists for
    /// and pin the shim to a published archive: a local file URL there would fail on every machine.
    func testLsfgVariantIsR6PlusAPinnedShim() throws {
        let lsfg = try XCTUnwrap(try manifests().first { $0.id == "x64-sikarugir10.0_6-r6-lsfg" }, "lsfg manifest missing")
        let r6 = try XCTUnwrap(try manifests().first { $0.id == "x64-sikarugir10.0_6-r6" }, "r6 manifest missing")
        XCTAssertEqual(lsfg.minMacOS, r6.minMacOS)
        XCTAssertEqual(lsfg.baseEnv?["D3DM_MTL4"], "0", "the lsfg variant must keep r6's Metal 4 backend setting")
        for (name, component) in r6.components {
            XCTAssertEqual(lsfg.components[name]?.sha256, component.sha256, "\(name) drifted from r6, so its download is not reused")
        }
        let shim = try XCTUnwrap(lsfg.components["lsfg"], "no lsfg component")
        XCTAssertEqual(shim.extract?.into, "renderers/lsfg", "resolveLsfgShimDir looks for renderers/lsfg")
        XCTAssertEqual(shim.license, "MIT")
        XCTAssertEqual(shim.url.scheme, "https", "the shim must come from a published archive, not a build machine")
    }
}
