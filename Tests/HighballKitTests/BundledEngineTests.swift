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

    /// Frame generation rides in the engines as one component, off unless an environment asks
    /// (itsOwen's lsfg-metal, highball#171): r9 is r5 plus that component on the main line, r10 is
    /// r6 plus the same one on the GPTK 4 line, and r7 and r8 are the revisions they replace, kept
    /// for rollback on the shim they pinned. All keep everything their base exists for, and the
    /// shim comes from Highball's own release (a component URL has to be ours to stay
    /// immutable; winetricks' branch URL drifting broke every fresh install once, #27/#28).
    func testFrameGenerationEnginesAreTheirBasePlusOnePinnedShim() throws {
        // The default engine lives in spike/engine-manifest.json, beside the spike/engines set.
        let all = try manifests() + [try EngineManifest.load(from: engines.deletingLastPathComponent().appending(path: "engine-manifest.json"))]
        func one(_ id: String) throws -> EngineManifest { try XCTUnwrap(all.first { $0.id == id }, "\(id) missing") }
        let v070 = ("fa496bb3947f52652fc3856c4a0413c7e5603e19c7dd6936dfc5d76be756b0f9", "https://github.com/gauthierpiarrette/highball/releases/download/engine-components/lsfg-metal-0.7.0.tar.xz")
        let v071 = ("39e05545fd26739d6b9bb419f87f426333d8342c1d71476d42b6c7845fb2787e", "https://github.com/itsOwen/lsfg-metal/releases/download/v0.7.1/lsfg-v0.7.1.tar.xz")
        for (variantID, baseID, shim071) in [("x64-sikarugir10.0_6-r9", "x64-sikarugir10.0_6-r5", true), ("x64-sikarugir10.0_6-r10", "x64-sikarugir10.0_6-r6", true), ("x64-sikarugir10.0_6-r7", "x64-sikarugir10.0_6-r5", false), ("x64-sikarugir10.0_6-r8", "x64-sikarugir10.0_6-r6", false)] {
            let variant = try one(variantID), base = try one(baseID)
            XCTAssertEqual(variant.minMacOS, base.minMacOS, "\(variantID) must keep \(baseID)'s floor")
            XCTAssertEqual(variant.baseEnv?["D3DM_MTL4"], base.baseEnv?["D3DM_MTL4"], "\(variantID) must keep \(baseID)'s Metal 4 setting")
            for (name, component) in base.components {
                XCTAssertEqual(variant.components[name]?.sha256, component.sha256, "\(name) drifted from \(baseID), so its download is not reused")
            }
            XCTAssertEqual(Set(variant.components.keys).subtracting(base.components.keys), ["lsfg"], "\(variantID) adds exactly the lsfg component")
            let shim = try XCTUnwrap(variant.components["lsfg"], "no lsfg component in \(variantID)")
            XCTAssertEqual(shim.extract?.into, "renderers/lsfg", "resolveLsfgShimDir looks for renderers/lsfg")
            XCTAssertEqual(shim.license, "MIT")
            let (sha, url) = shim071 ? v071 : v070
            XCTAssertEqual(shim.sha256, sha, "\(variantID) pins the asset verified against the published release")
            XCTAssertEqual(shim.url.absoluteString, url)
        }
        XCTAssertEqual(all.last?.id, "x64-sikarugir10.0_6-r9", "r9 is the default engine")
    }
}
