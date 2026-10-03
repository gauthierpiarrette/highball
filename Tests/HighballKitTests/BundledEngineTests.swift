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

    /// Frame generation left Highball on 2026-09-27 at its author's request (itsOwen's lsfg-metal,
    /// highball#171): no engine may ship the component any more. The revisions since are their
    /// bases (r5 on the main line, r6 on the GPTK 4 line) with DXMT swapped and one file added.
    /// DXMT moved from upstream's v0.80 release to Highball's own build on 2026-09-28, because
    /// v0.80's D3DKMT adapter lookup fails on this Wine and every shared texture then died at
    /// creation (ContractVille, highball#202). The Mac driver's winemac.so is replaced on
    /// 2026-09-30 so a game gets its focus back after the player leaves it (highball#182), and
    /// wineserver and ntdll.so on 2026-10-01 so msync stops leaking wait registrations (highball#224),
    /// and the audio buffer library is added the same day so games stop dropping sound (highball#127).
    /// Everything else is byte-identical, so it is not downloaded again, and every new archive
    /// comes from Highball's own release pages (a component URL has to be ours to stay immutable,
    /// #27/#28).
    func testNoEngineShipsFrameGenerationAndTheCurrentRevisionsAreTheirBasesPlusOurDXMTAndDriver() throws {
        let all = try manifests() + [try EngineManifest.load(from: engines.deletingLastPathComponent().appending(path: "engine-manifest.json"))]
        for m in all {
            XCTAssertNil(m.components["lsfg"], "\(m.id) still ships the lsfg component")
            for (name, c) in m.components {
                XCTAssertFalse(c.url.absoluteString.lowercased().contains("lsfg"), "\(m.id)/\(name) still points at an lsfg archive")
            }
        }
        func one(_ id: String) throws -> EngineManifest { try XCTUnwrap(all.first { $0.id == id }, "\(id) missing") }
        for (current, baseID) in [("x64-sikarugir10.0_6-r19", "x64-sikarugir10.0_6-r5"), ("x64-sikarugir10.0_6-r20", "x64-sikarugir10.0_6-r6")] {
            let r = try one(current), base = try one(baseID)
            XCTAssertEqual(r.minMacOS, base.minMacOS, "\(current) must keep \(baseID)'s floor")
            XCTAssertEqual(r.baseEnv?["D3DM_MTL4"], base.baseEnv?["D3DM_MTL4"], "\(current) must keep \(baseID)'s Metal 4 setting")
            XCTAssertEqual(Set(r.components.keys), Set(base.components.keys).union(["winemac", "wineserver", "ntdll-unix", "audiobuf"]),
                           "\(current) has exactly \(baseID)'s components plus the driver, the msync fix and the audio library")
            for (name, component) in base.components where name != "dxmt" {
                XCTAssertEqual(r.components[name]?.sha256, component.sha256, "\(name) drifted from \(baseID), so its download is not reused")
            }
            let dxmt = try XCTUnwrap(r.components["dxmt"])
            XCTAssertTrue(dxmt.url.absoluteString.hasPrefix("https://github.com/gauthierpiarrette/highball-engine/releases/download/dxmt-highball-"),
                          "\(current)'s DXMT must be Highball's own build from its release page: \(dxmt.url)")
            XCTAssertNotEqual(dxmt.sha256, base.components["dxmt"]?.sha256, "\(current) must not carry \(baseID)'s v0.80 DXMT")

            // The driver file is three byte edits to the Wine archive's own winemac.so
            // (Scripts/build-winemac-focus.sh checks every byte it touches), so it is only valid
            // over that exact archive, and only if it lands after it and on that one file.
            let winemac = try XCTUnwrap(r.components["winemac"])
            XCTAssertEqual(r.components["wine"]?.sha256, "9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2",
                           "\(current)'s driver was made for the Sikarugir 10.0_6 archive and no other")
            XCTAssertEqual(winemac.extract?.into, "engine/lib/wine/x86_64-unix/winemac.so", "the driver replaces one file, the Wine archive's own")
            XCTAssertGreaterThan(winemac.order ?? 0, r.components["wine"]?.order ?? 0, "the driver must unpack after the Wine archive it replaces a file of")
            XCTAssertTrue(winemac.url.absoluteString.hasPrefix("https://github.com/gauthierpiarrette/highball-engine/releases/download/winemac-focus-"),
                          "\(current)'s driver must come from Highball's own release page: \(winemac.url)")

            // The msync fix is byte edits to the same archive's wineserver and ntdll.so
            // (Scripts/build-wine10-msync.sh), one archive behind two single-file components.
            for (name, into) in [("wineserver", "engine/bin/wineserver"), ("ntdll-unix", "engine/lib/wine/x86_64-unix/ntdll.so")] {
                let c = try XCTUnwrap(r.components[name])
                XCTAssertEqual(c.extract?.into, into, "\(current)/\(name) replaces one file, the Wine archive's own")
                XCTAssertGreaterThan(c.order ?? 0, r.components["wine"]?.order ?? 0, "\(current)/\(name) must unpack after the Wine archive")
                XCTAssertTrue(c.url.absoluteString.hasPrefix("https://github.com/gauthierpiarrette/highball-engine/releases/download/wine10-msync-"),
                              "\(current)/\(name) must come from Highball's own release page: \(c.url)")
            }
            XCTAssertEqual(r.components["wineserver"]?.sha256, r.components["ntdll-unix"]?.sha256, "both files come from one archive, downloaded once")
            XCTAssertFalse(EngineManifest.needsPrefixRefresh(from: base, to: r), "\(current) keeps the Wine archive, so environments move without the Windows setup")

            // The audio library lands where InstalledEngine.audioBufferLibrary looks for it, from
            // Highball's own release page.
            let audio = try XCTUnwrap(r.components["audiobuf"])
            XCTAssertEqual(audio.extract?.into, "frameworks/libhbaudiobuf.dylib", "\(current)'s audio library must land where Bottle.environment looks")
            XCTAssertTrue(audio.url.absoluteString.hasPrefix("https://github.com/gauthierpiarrette/highball-engine/releases/download/audiobuf-"),
                          "\(current)'s audio library must come from Highball's own release page: \(audio.url)")
        }
        XCTAssertEqual(all.last?.id, "x64-sikarugir10.0_6-r19", "r19 is the default engine")
        // The update to r19 moves r17 environments straight over, and leaves GPTK 4 ones (r18) for
        // their own line's r20, which is where the walk must send them.
        let shipped = Set(all.flatMap { $0.components.keys })
        XCTAssertTrue(EngineStore.canMoveBottle(on: try one("x64-sikarugir10.0_6-r17"), to: try one("x64-sikarugir10.0_6-r19"), shipped: shipped))
        XCTAssertFalse(EngineStore.canMoveBottle(on: try one("x64-sikarugir10.0_6-r18"), to: try one("x64-sikarugir10.0_6-r19"), shipped: shipped))
        XCTAssertEqual(EngineStore.successor(for: try one("x64-sikarugir10.0_6-r18"), among: all, shipped: shipped, macOS: "27.0")?.id,
                       "x64-sikarugir10.0_6-r20")
        for rollback in ["x64-sikarugir10.0_6-r13", "x64-sikarugir10.0_6-r15", "x64-sikarugir10.0_6-r17"] {
            XCTAssertNotNil(all.first { $0.id == rollback }, "\(rollback) stays offered for rollback")
        }
    }
}
