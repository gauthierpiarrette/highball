import XCTest
@testable import HighballKit

/// The arm64 engine line (private/notes/rosetta-transition-plan.md, for macOS 28's end of Rosetta):
/// the app derives every architecture-specific path from the manifest, needs Rosetta only for the
/// engines that say so, and runs an arm64 engine through the signed loader helper in Highball.app,
/// never through the engine's own loader. Nothing here runs Wine; the layouts are what the M4 spike
/// of 2026-10-04 measured working.
final class EngineArchTests: XCTestCase {
    private func manifest(_ arch: String, requires: [String]? = nil) -> EngineManifest {
        var m = EngineManifest(id: "\(arch == "arm64" ? "arm64" : "x64")-test-r1", displayName: "test", arch: arch, minMacOS: "26.5", components: [:])
        m.requires = requires
        return m
    }

    private func tempRoot(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: Environments stay on one architecture

    /// No prefix has been moved between the Intel engines and the arm64 line, so the picker and
    /// the failure advice never offer it; a recipe's engine ask offers a new environment instead.
    func testEnvironmentsMoveOnlyWithinOneArchitecture() {
        let intel = manifest("x86_64"), arm = manifest("arm64")
        var intel2 = intel; intel2.id = "x64-test-r2"
        let root = tempRoot("hb-arch-move")
        let installed = [InstalledEngine(manifest: intel, root: root.appending(path: intel.id)),
                         InstalledEngine(manifest: arm, root: root.appending(path: arm.id))]
        XCTAssertEqual(EngineStore.offeredEngines(installed: installed, known: [intel2], current: intel.id, macOS: "27.0").map(\.id),
                       ["x64-test-r1", "x64-test-r2"])
        XCTAssertEqual(EngineStore.offeredEngines(installed: installed, known: [intel2], current: arm.id, macOS: "27.0").map(\.id),
                       ["arm64-test-r1"])
        XCTAssertEqual(Set(EngineStore.offeredEngines(installed: installed, known: [intel2], current: "gone-r1", macOS: "27.0").map(\.id)),
                       ["x64-test-r1", "arm64-test-r1", "x64-test-r2", "gone-r1"], "an environment whose engine is gone keeps every choice")
        XCTAssertNil(EngineStore.alternateEngine(for: arm.id, installed: installed, defaultID: intel.id), "an Intel default is no advice for an arm64 environment")
        XCTAssertNil(EngineStore.alternateEngine(for: intel.id, installed: installed, defaultID: nil))
        XCTAssertTrue(EngineStore.sameArch(current: nil, target: "arm64"))
        XCTAssertFalse(EngineStore.sameArch(current: "x86_64", target: "arm64"))
        XCTAssertFalse(EngineStore.sameArch(current: "arm64", target: "x86_64"))
    }

    /// highball-db#537: with the preview key set, the arm64 line showed nowhere a player could pick it.
    /// New environment offers the newest revision of each line of the other architecture, and nothing
    /// when there is none.
    func testNewEnvironmentOffersTheOtherArchitecturesNewestRevision() {
        let intel = manifest("x86_64", requires: ["rosetta2"])
        var arm1 = manifest("arm64"), arm6 = manifest("arm64"), arm10 = manifest("arm64"), future = manifest("arm64"), other = manifest("arm64")
        arm1.id = "arm64-wine11.18-r1"; arm6.id = "arm64-wine11.18-r6"; arm10.id = "arm64-wine11.18-r10"
        future.id = "arm64-wine12.0-r1"; future.minMacOS = "28.0"
        other.id = "arm64-wine11.20-r2"
        let root = tempRoot("hb-new-env")
        let installed = [InstalledEngine(manifest: intel, root: root.appending(path: intel.id)),
                         InstalledEngine(manifest: arm1, root: root.appending(path: arm1.id))]
        XCTAssertEqual(EngineStore.newEnvironmentAlternatives(defaultArch: "x86_64", installed: installed, known: [arm6, arm10, future, other], macOS: "27.0.1"),
                       ["arm64-wine11.20-r2", "arm64-wine11.18-r10"], "one row per line, newest revision, nothing above this macOS")
        XCTAssertEqual(EngineStore.newEnvironmentAlternatives(defaultArch: "x86_64", installed: installed, known: [], macOS: "27.0"),
                       ["arm64-wine11.18-r1"], "an installed engine counts without its manifest")
        XCTAssertEqual(EngineStore.newEnvironmentAlternatives(defaultArch: "x86_64", installed: Array(installed.prefix(1)), known: [], macOS: "27.0"), [],
                       "nothing to choose, nothing asked")
        XCTAssertEqual(EngineStore.newEnvironmentAlternatives(defaultArch: "arm64", installed: installed, known: [arm6], macOS: "27.0"),
                       ["x64-test-r1"], "the same rule the other way round")
    }

    /// highball#413: Rosetta would not install, so Get started failed while the arm64 line was bundled.
    func testSetupWithoutRosettaTakesTheNewestNativeEngineItSees() {
        let intel = manifest("x86_64", requires: ["rosetta2"])
        var arm5 = manifest("arm64", requires: []), arm6 = manifest("arm64", requires: []), floor28 = manifest("arm64", requires: [])
        arm5.id = "arm64-wine11.18-r5"; arm6.id = "arm64-wine11.18-r6"; floor28.id = "arm64-wine11.18-r9"; floor28.minMacOS = "28.0"
        XCTAssertEqual(EngineStore.startingEngineWithoutRosetta(known: [intel, arm5, arm6, floor28], macOS: "27.0.1")?.id, "arm64-wine11.18-r6")
        XCTAssertNil(EngineStore.startingEngineWithoutRosetta(known: [intel], macOS: "27.0.1"), "without the preview key there is none")
    }

    func testTheDownloadSizeCountsEachArchiveOnce() {
        var m = manifest("arm64")
        let renderers = URL(string: "https://example.com/renderers-arm64.tar.xz")!
        m.components["vkd3d"] = EngineManifest.Component(kind: "renderer", url: renderers, sha256: "a", size: 100)
        m.components["dxvk"] = EngineManifest.Component(kind: "renderer", url: renderers, sha256: "a", size: 100)
        m.components["wine"] = EngineManifest.Component(kind: "wine", url: URL(string: "https://example.com/wine.tar.xz")!, sha256: "b", size: 50)
        XCTAssertEqual(m.downloadBytes, 150, "two folders of one archive are one download")
    }

    func testDirectoriesFollowTheArchitecture() {
        let intel = manifest("x86_64"), arm = manifest("arm64")
        XCTAssertEqual(intel.pe64LibDir, "x86_64-windows")
        XCTAssertEqual(intel.unixLibDir, "x86_64-unix")
        XCTAssertEqual(arm.pe64LibDir, "aarch64-windows", "Wine's ARM64X builtins, with the ARM64EC code x86-64 programs call into")
        XCTAssertEqual(arm.unixLibDir, "aarch64-unix")
        XCTAssertEqual(EngineManifest.pe32LibDir, "i386-windows", "32-bit programs run through WoW64 on both lines")
        XCTAssertFalse(intel.isNativeARM64); XCTAssertTrue(arm.isNativeARM64)
        XCTAssertEqual(EngineIntegrity.libraryDirectories(engineRoot: URL(fileURLWithPath: "/e"), arch: "arm64").map(\.lastPathComponent),
                       ["aarch64-windows", "i386-windows"])
        XCTAssertEqual(EngineIntegrity.libraryDirectories(engineRoot: URL(fileURLWithPath: "/e")).map(\.lastPathComponent),
                       ["x86_64-windows", "i386-windows"], "the default stays the Intel layout every shipped engine has")
    }

    /// An arm64 engine's Wine opens MoltenVK and its other host libraries by leaf name, and the
    /// GStreamer framework carries a stock libMoltenVK: the engine's lib leads the fallback path so
    /// winevulkan gets the patched copy (the first app launch got the framework's, 2026-10-15).
    func testAnArm64EngineOpensItsOwnHostLibrariesFirst() {
        let root = URL(fileURLWithPath: "/e")
        let arm = InstalledEngine(manifest: manifest("arm64"), root: root).baseEnvironment()["DYLD_FALLBACK_LIBRARY_PATH"]!
        XCTAssertTrue(arm.hasPrefix("/e/engine/lib:"), arm)
        XCTAssertTrue(arm.contains("/e/frameworks/GStreamer.framework/Versions/1.0/lib"), "the framework's plugins still find their libraries")
        let intel = InstalledEngine(manifest: manifest("x86_64"), root: root).baseEnvironment()["DYLD_FALLBACK_LIBRARY_PATH"]!
        XCTAssertTrue(intel.hasPrefix("/e/frameworks:"), "the Intel line is unchanged, its engine/lib links resolve through rpath")
    }

    func testOnlyEnginesThatSaySoNeedRosetta() throws {
        XCTAssertTrue(manifest("x86_64", requires: ["rosetta2"]).requiresRosetta)
        XCTAssertFalse(manifest("arm64", requires: []).requiresRosetta)
        XCTAssertFalse(manifest("arm64").requiresRosetta, "no requires at all means nothing is required")
        // Every Intel engine shipped must keep saying so, or the app would stop installing Rosetta
        // for it; the native arm64 line (arm64-wine11.18-r1 since 2026-10-15) runs x86-64 code
        // through FEX inside Wine and must not ask for Rosetta.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "spike")
        var files = try FileManager.default.contentsOfDirectory(at: dir.appending(path: "engines"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        files.append(dir.appending(path: "engine-manifest.json"))
        var intel = 0, arm = 0
        for f in files {
            let m = try EngineManifest.load(from: f)
            if m.isNativeARM64 {
                arm += 1
                XCTAssertFalse(m.requiresRosetta, "\(m.id) is native arm64 and must not ask for Rosetta")
            } else {
                intel += 1
                XCTAssertEqual(m.arch, "x86_64", "\(m.id) is not an Intel engine")
                XCTAssertTrue(m.requiresRosetta, "\(m.id) no longer declares rosetta2")
            }
        }
        XCTAssertGreaterThan(intel, 0, "the Intel engines are still shipped")
        XCTAssertGreaterThan(arm, 0, "the arm64 line's manifest is shipped")
    }

    func testAnARM64EngineNeedsFEXAndTheSignedLoader() throws {
        let arm = manifest("arm64")
        let files = InstalledEngine.requiredFiles(for: arm)
        XCTAssertTrue(files.contains("engine/lib/wine/aarch64-windows/kernel32.dll"))
        XCTAssertTrue(files.contains("engine/lib/wine/aarch64-unix/ntdll.so"))
        XCTAssertTrue(files.contains("engine/lib/wine/i386-windows/kernel32.dll"))
        XCTAssertFalse(files.contains { $0.contains("x86_64") }, "nothing Intel is expected of an arm64 engine")
        for fex in ["engine/lib/wine/aarch64-windows/xtajit64.dll", "engine/lib/wine/aarch64-windows/xtajit.dll",
                    "engine/lib/wine/aarch64-unix/libarm64ecfex.so", "engine/lib/wine/aarch64-unix/libwow64fex.so"] {
            XCTAssertTrue(files.contains(fex), "\(fex) is what makes x86 programs run at all")
        }
        XCTAssertEqual(InstalledEngine.requiredFiles, InstalledEngine.requiredFiles(for: manifest("x86_64")), "the Intel list is unchanged")

        // A tree with every file, but the loader is the engine's own: not complete.
        let root = tempRoot("arm64-engine")
        for f in files { try touch(root.appending(path: f)) }
        let engine = InstalledEngine(manifest: arm, root: root)
        XCTAssertEqual(engine.missingFiles, [InstalledEngine.signedLoaderName])
        XCTAssertFalse(engine.usesSignedLoader)

        // Linking the signed helper completes it, sets the engine's loader aside once, and makes
        // bin/wine the relative link Wine itself installs, so a start through either path reaches
        // the helper and finds ntdll.so beside the Unix-side link.
        let app = tempRoot("Highball.app").appendingPathExtension("app")
        let helper = WineLoaderHelper.binary(inAppBundle: app)
        try touch(helper)
        try EngineStore().linkSignedLoader(root, manifest: arm, helper: helper)
        let unixLink = root.appending(path: "engine/lib/wine/aarch64-unix/wine")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: unixLink.path), helper.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(path: "engine/bin/wine").path), "../lib/wine/aarch64-unix/wine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "engine/bin/wine.unsigned").path), "the engine's own loader is kept aside")
        XCTAssertTrue(engine.usesSignedLoader)
        XCTAssertEqual(engine.missingFiles, [])
        XCTAssertEqual(engine.wineBinary.resolvingSymlinksInPath().path, helper.resolvingSymlinksInPath().path, "a launch runs the helper")

        // The app moved: the next read repoints the link and nothing else changes.
        let moved = tempRoot("Moved.app").appendingPathExtension("app")
        let helper2 = WineLoaderHelper.binary(inAppBundle: moved)
        try touch(helper2)
        try EngineStore().linkSignedLoader(root, manifest: arm, helper: helper2)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: unixLink.path), helper2.path)
        XCTAssertEqual(engine.missingFiles, [])

        // An Intel engine is never touched.
        let intelRoot = tempRoot("x64-engine")
        try touch(intelRoot.appending(path: "engine/bin/wine"))
        try EngineStore().linkSignedLoader(intelRoot, manifest: manifest("x86_64", requires: ["rosetta2"]), helper: helper)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: intelRoot.appending(path: "engine/bin/wine").path))
    }

    /// An unsigned copy of a real executable, which is what the engine CI ships as an Intel `wine`.
    private func unsignedExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url)
        try Shell.run("/usr/bin/codesign", ["--remove-signature", url.path])
    }

    /// The Neural Engine daemon refuses a process with no signing identifier, so MetalFX's scaler
    /// network fell back to the GPU and timed out there (EngineStore.signIntelLoader). An Intel
    /// engine's loader gets an ad-hoc signature that names it. A signed loader, a file that is not
    /// Mach-O and an arm64 engine are left as they are.
    func testAnIntelEnginesUnsignedLoaderIsSignedWithAnIdentifier() throws {
        let intel = manifest("x86_64", requires: ["rosetta2"])
        let root = tempRoot("x64-engine-sign")
        let launcher = root.appending(path: "engine/bin/wine"), loader = root.appending(path: "engine/lib/wine/x86_64-unix/wine")
        let server = root.appending(path: "engine/bin/wineserver")
        for url in [launcher, loader, server] { try unsignedExecutable(at: url) }
        XCTAssertTrue(EngineStore.isUnsignedMachO(loader), "the test starts from what CI ships")

        try EngineStore().signIntelLoader(root, manifest: intel)
        for url in [launcher, loader] {
            XCTAssertEqual(EngineStore.signingIdentifier(of: url), EngineStore.intelLoaderIdentifier, url.lastPathComponent)
            XCTAssertFalse(EngineStore.isUnsignedMachO(url))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "the copy keeps its mode")
            XCTAssertNoThrow(try Shell.run(url.path, []), "a signed loader still starts")
        }
        XCTAssertTrue(EngineStore.isUnsignedMachO(server), "only the loader hosts Windows programs")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: loader.deletingLastPathComponent().path), ["wine"], "no signing copy is left behind")

        // A second read changes nothing.
        let signed = try EngineStore().sha256(of: loader)
        try EngineStore().signIntelLoader(root, manifest: intel)
        XCTAssertEqual(try EngineStore().sha256(of: loader), signed)

        // A loader that came signed keeps its own signature.
        let other = tempRoot("x64-engine-presigned")
        let presigned = other.appending(path: "engine/bin/wine")
        try unsignedExecutable(at: presigned)
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "org.winehq.wine", presigned.path])
        try EngineStore().signIntelLoader(other, manifest: intel)
        XCTAssertEqual(EngineStore.signingIdentifier(of: presigned), "org.winehq.wine")

        // A file that is not Mach-O, as the layout tests write, is never signed into its attributes.
        let fake = tempRoot("x64-engine-fake")
        try touch(fake.appending(path: "engine/bin/wine"))
        XCTAssertFalse(EngineStore.isUnsignedMachO(fake.appending(path: "engine/bin/wine")))
        try EngineStore().signIntelLoader(fake, manifest: intel)
        XCTAssertNil(EngineStore.signingIdentifier(of: fake.appending(path: "engine/bin/wine")))

        // An arm64 engine is the helper's business.
        let arm = tempRoot("arm64-engine-sign")
        let armLoader = arm.appending(path: "engine/lib/wine/aarch64-unix/wine")
        try unsignedExecutable(at: armLoader)
        try EngineStore().signIntelLoader(arm, manifest: manifest("arm64"))
        XCTAssertTrue(EngineStore.isUnsignedMachO(armLoader))
    }

    func testTheHelperIsFoundInTheEnvironmentThenTheAppThenApplications() throws {
        let app = tempRoot("App").appendingPathExtension("app"), installed = tempRoot("Installed").appendingPathExtension("app")
        let nowhere = URL(fileURLWithPath: "/nonexistent/Highball.app")
        XCTAssertNil(WineLoaderHelper.locate(environment: [:], appBundle: app, applications: nowhere), "nothing on disk yet")
        try touch(WineLoaderHelper.binary(inAppBundle: installed))
        XCTAssertEqual(WineLoaderHelper.locate(environment: [:], appBundle: app, applications: installed), WineLoaderHelper.binary(inAppBundle: installed))
        try touch(WineLoaderHelper.binary(inAppBundle: app))
        XCTAssertEqual(WineLoaderHelper.locate(environment: [:], appBundle: app, applications: installed), WineLoaderHelper.binary(inAppBundle: app),
                       "the running app's own helper wins over the one in Applications")
        let override = tempRoot("Override").appendingPathExtension("app")
        try touch(WineLoaderHelper.binary(inAppBundle: override))
        let bundlePath = override.appending(path: "Contents/Helpers/WineLoader.app").path
        XCTAssertEqual(WineLoaderHelper.locate(environment: [WineLoaderHelper.environmentKey: bundlePath], appBundle: app, applications: installed),
                       WineLoaderHelper.binary(inAppBundle: override), "the environment names the bundle")
        XCTAssertEqual(WineLoaderHelper.locate(environment: [WineLoaderHelper.environmentKey: WineLoaderHelper.binary(inAppBundle: override).path], appBundle: app, applications: installed),
                       WineLoaderHelper.binary(inAppBundle: override), "or the binary")
        XCTAssertEqual(WineLoaderHelper.locate(environment: [WineLoaderHelper.environmentKey: "/nonexistent/wine"], appBundle: app, applications: installed),
                       WineLoaderHelper.binary(inAppBundle: app), "a wrong override falls through")
        // The CLI on a Mac without the app: a non-bundle main executable has no helper of its own.
        XCTAssertEqual(WineLoaderHelper.locate(environment: [:], appBundle: URL(fileURLWithPath: "/usr/local/bin/highball"), applications: installed),
                       WineLoaderHelper.binary(inAppBundle: installed))
    }

    func testTheRosettaSwitchOnlyReachesRosettaEngines() throws {
        // Bottle.environment sets ROSETTA_ADVERTISE_AVX for an Intel engine (EnvironmentTests) and
        // must not for an arm64 one, where x86 code runs through FEX and the variable means nothing.
        var bottle = Bottle(url: URL(fileURLWithPath: "/tmp/hb-arch-test-bottle"), settings: BottleSettings(name: "t", engineID: "arm64-test-r1"))
        bottle.settings.advertiseAVX = true
        let arm = InstalledEngine(manifest: manifest("arm64"), root: tempRoot("arm64-engine"))
        XCTAssertNil(try bottle.environment(engine: arm, renderer: .wined3d)["ROSETTA_ADVERTISE_AVX"])
        let intel = InstalledEngine(manifest: manifest("x86_64", requires: ["rosetta2"]), root: tempRoot("x64-engine"))
        XCTAssertEqual(try bottle.environment(engine: intel, renderer: .wined3d)["ROSETTA_ADVERTISE_AVX"], "1")
    }

    func testMoltenVKLogsWarningsNotItsExtensionList() throws {
        var bottle = Bottle(url: URL(fileURLWithPath: "/tmp/hb-arch-test-bottle"), settings: BottleSettings(name: "t", engineID: "x64-test-r1"))
        let intel = InstalledEngine(manifest: manifest("x86_64", requires: ["rosetta2"]), root: tempRoot("x64-engine"))
        XCTAssertEqual(try bottle.environment(engine: intel, renderer: .wined3d)["MVK_CONFIG_LOG_LEVEL"], "2", "warnings and errors only")
        bottle.settings.environment["MVK_CONFIG_LOG_LEVEL"] = "3"
        XCTAssertEqual(try bottle.environment(engine: intel, renderer: .wined3d)["MVK_CONFIG_LOG_LEVEL"], "3", "a player's own level wins")
    }
}
