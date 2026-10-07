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

    /// r19 is r17 with a rebuilt Wine (patches 0017 to 0019) and the new shim; r18 is the same
    /// plus D3DMetal 4 for the games that need it (Forza Horizon 6), numbered below on purpose,
    /// like the Wine 10 line's r20 under r21: a recipe pinning an earlier Wine 11 revision is
    /// offered the newest revision carrying its pin, which must stay a D3DMetal 3 one, so the
    /// verified D3DMetal games on that line (Guardians, Persona 5 Royal...) keep their D3DMetal.
    func testR19IsR17WithTheNewWineAndShimAndR18AddsOnlyD3DMetal4() throws {
        let all = try manifests()
        func one(_ id: String) throws -> EngineManifest { try XCTUnwrap(all.first { $0.id == id }, "\(id) missing") }
        let r17 = try one("x64-crossover26.3-r17"), r18 = try one("x64-crossover26.3-r18"), r19 = try one("x64-crossover26.3-r19")
        XCTAssertEqual(r19.minMacOS, r17.minMacOS, "r19 must keep r17's floor")
        XCTAssertEqual(Set(r19.components.keys), Set(r17.components.keys))
        for (name, c) in r17.components where name != "wine" && name != "d3dmetal-tsshim" {
            XCTAssertEqual(r19.components[name]?.sha256, c.sha256, "\(name) drifted from r17, so its download is not reused")
        }
        XCTAssertNotEqual(r19.components["wine"]?.sha256, r17.components["wine"]?.sha256, "r19 carries the rebuilt Wine")
        for (name, c) in r19.components {
            XCTAssertEqual(r18.components[name]?.sha256, c.sha256, "r18 must carry r19's \(name) unchanged")
        }
        XCTAssertEqual(Set(r18.components.keys), Set(r19.components.keys).union(["d3dmetal"]))
        XCTAssertEqual(r18.minMacOS, "27.0")
        XCTAssertFalse(r18.runs(onMacOS: "26.6.2"), "D3DMetal 4 is measured on macOS 27 only")
        XCTAssertEqual(r18.baseEnv?["D3DM_MTL4"], "0", "the Metal 4 backend ends UE5 titles within a minute on 4.0b2")
        XCTAssertEqual(r18.components["d3dmetal"]?.sha256, try one("x64-sikarugir10.0_6-r20").components["d3dmetal"]?.sha256,
                       "the same D3DMetal 4 component as the Wine 10 line, downloaded once")
        XCTAssertFalse(EngineManifest.satisfies(current: r19, wanted: r18), "r19 lacks D3DMetal 4")
        XCTAssertFalse(EngineManifest.needsPrefixRefresh(from: r19, to: r18), "same Wine: moving between the two is cheap")
    }

    /// r21 is r19 and r20 is r18 with the Wine rebuilt for patch 0020 (the Mac driver stops doubling
    /// HORZRES and VERTRES in retina mode, highball#261), 0021 (GL_ARB_ES2_compatibility's calls in
    /// legacy OpenGL contexts, highball-db#349) and the refreshed 0012, numbered the same
    /// way: the D3DMetal 4 one below, so every older plain pin is offered the D3DMetal 3 revision
    /// and Forza Horizon 6's pin on r18 is offered r20.
    func testR21AndR20AreR19AndR18WithTheRetinaFixedWine() throws {
        let all = try manifests()
        func one(_ id: String) throws -> EngineManifest { try XCTUnwrap(all.first { $0.id == id }, "\(id) missing") }
        for (new, old) in [("x64-crossover26.3-r21", "x64-crossover26.3-r19"), ("x64-crossover26.3-r20", "x64-crossover26.3-r18")] {
            let n = try one(new), o = try one(old)
            XCTAssertEqual(Set(n.components.keys), Set(o.components.keys), "\(new) has \(old)'s components")
            for (name, c) in o.components where name != "wine" {
                XCTAssertEqual(n.components[name]?.sha256, c.sha256, "\(new)/\(name) must be \(old)'s, only Wine is rebuilt")
            }
            XCTAssertNotEqual(n.components["wine"]?.sha256, o.components["wine"]?.sha256, "\(new) carries the rebuilt Wine")
            XCTAssertTrue(n.components["wine"]?.url.absoluteString.hasPrefix("https://github.com/gauthierpiarrette/highball-engine/releases/download/engine-wine-11.0-") == true)
            XCTAssertEqual(n.minMacOS, o.minMacOS)
            XCTAssertEqual(n.baseEnv, o.baseEnv)
        }
        XCTAssertEqual(try one("x64-crossover26.3-r20").components["wine"]?.sha256, try one("x64-crossover26.3-r21").components["wine"]?.sha256,
                       "one Wine build behind both, downloaded once")
        // Every older plain Wine 11 pin is offered r21 on macOS 27, never the D3DMetal 4 one.
        for pin in ["x64-crossover26.3-r5", "x64-crossover26.3-r7", "x64-crossover26.3-r8", "x64-crossover26.3-r9", "x64-crossover26.3-r15", "x64-crossover26.3-r19"] {
            let wanted = try one(pin)
            let offered = all.filter { EngineManifest.satisfies(current: $0, wanted: wanted) && $0.runs(onMacOS: "27.0") }
                .max { (EngineManifest.revision(of: $0.id) ?? 0) < (EngineManifest.revision(of: $1.id) ?? 0) }
            XCTAssertEqual(offered?.id, "x64-crossover26.3-r21", "a pin on \(pin) must get the newest D3DMetal 3 revision")
        }
        let forzaPin = try one("x64-crossover26.3-r18")
        let forOffer = all.filter { EngineManifest.satisfies(current: $0, wanted: forzaPin) && $0.runs(onMacOS: "27.0") }
            .max { (EngineManifest.revision(of: $0.id) ?? 0) < (EngineManifest.revision(of: $1.id) ?? 0) }
        XCTAssertEqual(forOffer?.id, "x64-crossover26.3-r20", "Forza Horizon 6's pin gets the retina-fixed D3DMetal 4 revision")
        XCTAssertFalse(EngineManifest.satisfies(current: try one("x64-crossover26.3-r21"), wanted: forzaPin), "r21 lacks D3DMetal 4")
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
    /// On 2026-10-03 ntdll.so is replaced again (wineserver comes from the same archive) so data
    /// execution prevention stays on under Rosetta, where Wine turning it off made every write to
    /// an executable page fault (highball#165).
    /// On 2026-10-06 winemac.so gains a fourth edit so retina mode stops doubling HORZRES and
    /// VERTRES (highball#261), on the default line (r22) and on the D3DMetal 4 line (r23).
    /// On 2026-10-07 MoltenVK gains the shadow-readback patch, so a 32-bit Vulkan game's GPU results
    /// reach it under MVK_SHADOW_IMPORT=1 (The Sims' thumbnails, highball#283): r24 and r25.
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
        for (current, baseID) in [("x64-sikarugir10.0_6-r19", "x64-sikarugir10.0_6-r5"), ("x64-sikarugir10.0_6-r21", "x64-sikarugir10.0_6-r5"),
                                  ("x64-sikarugir10.0_6-r22", "x64-sikarugir10.0_6-r5"), ("x64-sikarugir10.0_6-r24", "x64-sikarugir10.0_6-r5"),
                                  ("x64-sikarugir10.0_6-r20", "x64-sikarugir10.0_6-r6"), ("x64-sikarugir10.0_6-r23", "x64-sikarugir10.0_6-r6"),
                                  ("x64-sikarugir10.0_6-r25", "x64-sikarugir10.0_6-r6")] {
            let r = try one(current), base = try one(baseID)
            XCTAssertEqual(r.minMacOS, base.minMacOS, "\(current) must keep \(baseID)'s floor")
            XCTAssertEqual(r.baseEnv?["D3DM_MTL4"], base.baseEnv?["D3DM_MTL4"], "\(current) must keep \(baseID)'s Metal 4 setting")
            XCTAssertEqual(Set(r.components.keys), Set(base.components.keys).union(["winemac", "wineserver", "ntdll-unix", "audiobuf"]),
                           "\(current) has exactly \(baseID)'s components plus the driver, the msync fix and the audio library")
            let readback: Set = ["x64-sikarugir10.0_6-r24", "x64-sikarugir10.0_6-r25"]
            for (name, component) in base.components where name != "dxmt" && !(name == "moltenvk" && readback.contains(current)) {
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
            // (Scripts/build-wine10-msync.sh), one archive behind two single-file components. r21's
            // archive (Scripts/build-wine10-dep.sh) carries those edits plus the DEP one.
            let archive = ["x64-sikarugir10.0_6-r21", "x64-sikarugir10.0_6-r22", "x64-sikarugir10.0_6-r24"].contains(current) ? "wine10-dep-" : "wine10-msync-"
            for (name, into) in [("wineserver", "engine/bin/wineserver"), ("ntdll-unix", "engine/lib/wine/x86_64-unix/ntdll.so")] {
                let c = try XCTUnwrap(r.components[name])
                XCTAssertEqual(c.extract?.into, into, "\(current)/\(name) replaces one file, the Wine archive's own")
                XCTAssertGreaterThan(c.order ?? 0, r.components["wine"]?.order ?? 0, "\(current)/\(name) must unpack after the Wine archive")
                XCTAssertTrue(c.url.absoluteString.hasPrefix("https://github.com/gauthierpiarrette/highball-engine/releases/download/\(archive)"),
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
        XCTAssertEqual(all.last?.id, "x64-sikarugir10.0_6-r24", "r24 is the default engine")
        // r22 and r23 are r21 and r20 with only the driver changed: the retina fix rides one new
        // archive, and every other download is reused.
        for (fixed, before) in [("x64-sikarugir10.0_6-r22", "x64-sikarugir10.0_6-r21"), ("x64-sikarugir10.0_6-r23", "x64-sikarugir10.0_6-r20")] {
            let r = try one(fixed), b = try one(before)
            XCTAssertEqual(r.components["winemac"]?.version, "20261006", "\(fixed) carries the retina-fixed driver")
            XCTAssertEqual(b.components["winemac"]?.version, "20260930", "\(before) keeps the driver it shipped with")
            for (name, c) in b.components where name != "winemac" {
                XCTAssertEqual(r.components[name]?.sha256, c.sha256, "\(fixed)/\(name) must be \(before)'s, only the driver changes")
            }
            XCTAssertEqual(r.minMacOS, b.minMacOS)
        }
        // r24 and r25 are r22 and r23 with only MoltenVK changed: one 1.7 MB archive, the same for both
        // lines, and every other download reused.
        for (fixed, before) in [("x64-sikarugir10.0_6-r24", "x64-sikarugir10.0_6-r22"), ("x64-sikarugir10.0_6-r25", "x64-sikarugir10.0_6-r23")] {
            let r = try one(fixed), b = try one(before)
            XCTAssertEqual(r.components["moltenvk"]?.version, "1.4.1+shadow-import-1+shadow-readback-1", "\(fixed) carries the readback MoltenVK")
            XCTAssertEqual(b.components["moltenvk"]?.version, "1.4.1+shadow-import-1", "\(before) keeps the MoltenVK it shipped with")
            XCTAssertTrue(r.components["moltenvk"]?.url.absoluteString.hasPrefix("https://github.com/gauthierpiarrette/highball/releases/download/engine-components/moltenvk-1.4.1-shadow-import-1-shadow-readback-1") == true,
                          "\(fixed)'s MoltenVK must come from Highball's own release page")
            XCTAssertEqual(r.components["moltenvk"]?.extract?.into, b.components["moltenvk"]?.extract?.into, "it replaces the same file")
            XCTAssertEqual(Set(r.components.keys), Set(b.components.keys))
            for (name, c) in b.components where name != "moltenvk" {
                XCTAssertEqual(r.components[name]?.sha256, c.sha256, "\(fixed)/\(name) must be \(before)'s, only MoltenVK changes")
            }
            XCTAssertEqual(r.minMacOS, b.minMacOS)
            XCTAssertEqual(r.baseEnv, b.baseEnv)
            XCTAssertFalse(EngineManifest.needsPrefixRefresh(from: b, to: r), "\(fixed) keeps the Wine archive, so environments move without the Windows setup")
        }
        XCTAssertEqual(try one("x64-sikarugir10.0_6-r24").components["moltenvk"]?.sha256, try one("x64-sikarugir10.0_6-r25").components["moltenvk"]?.sha256,
                       "one MoltenVK archive behind both lines, downloaded once")
        // The update to r21 moves r17 and r19 environments straight over, and leaves GPTK 4 ones (r18)
        // for their own line's r20, which is where the walk must send them.
        let shipped = Set(all.flatMap { $0.components.keys })
        for from in ["x64-sikarugir10.0_6-r17", "x64-sikarugir10.0_6-r19", "x64-sikarugir10.0_6-r21", "x64-sikarugir10.0_6-r22"] {
            XCTAssertTrue(EngineStore.canMoveBottle(on: try one(from), to: try one("x64-sikarugir10.0_6-r24"), shipped: shipped), "\(from) moves to r24")
        }
        XCTAssertFalse(EngineStore.canMoveBottle(on: try one("x64-sikarugir10.0_6-r18"), to: try one("x64-sikarugir10.0_6-r24"), shipped: shipped))
        for gptk4 in ["x64-sikarugir10.0_6-r18", "x64-sikarugir10.0_6-r20", "x64-sikarugir10.0_6-r23"] {
            XCTAssertEqual(EngineStore.successor(for: try one(gptk4), among: all, shipped: shipped, macOS: "27.0")?.id,
                           "x64-sikarugir10.0_6-r25", "\(gptk4) environments stay on the D3DMetal 4 line and get its fixes")
        }
        // r25 is numbered above r24, but a default-line environment left behind still takes r24: the walk
        // prefers the variant adding no component over the newest.
        XCTAssertEqual(EngineStore.successor(for: try one("x64-sikarugir10.0_6-r22"), among: all, shipped: shipped, macOS: "27.0")?.id,
                       "x64-sikarugir10.0_6-r24", "a default-line environment must not move to the D3DMetal 4 line")
        for rollback in ["x64-sikarugir10.0_6-r13", "x64-sikarugir10.0_6-r15", "x64-sikarugir10.0_6-r17", "x64-sikarugir10.0_6-r19", "x64-sikarugir10.0_6-r21",
                         "x64-sikarugir10.0_6-r22", "x64-sikarugir10.0_6-r23"] {
            XCTAssertNotNil(all.first { $0.id == rollback }, "\(rollback) stays offered for rollback")
        }
    }
}
