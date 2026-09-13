import Foundation
import CryptoKit
@testable import HighballKit

private func frameGenerationChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "hb-framegen-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw HighballError.failed(message) }
    }
    func file(_ url: URL, _ data: String = "fixture") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data.utf8).write(to: url)
    }
    let manifest = try EngineManifest.load(from: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "spike/engine-manifest.json"))
    let engine = InstalledEngine(manifest: manifest, root: root.appending(path: "engine"))
    var bottle = Bottle(url: root.appending(path: "bottle"), settings: BottleSettings(name: "audit", engineID: manifest.id))
    for renderer in ["dxvk", "d9vk", "dxmt", "vkd3d"] {
        try fm.createDirectory(at: engine.renderersDir.appending(path: "\(renderer)/wine"), withIntermediateDirectories: true)
    }
    bottle.settings.frameGen = 2
    let shim = engine.renderersDir.appending(path: "lsfg")
    let driver = engine.frameworksDir.appending(path: "libMoltenVK.dylib")
    try file(shim.appending(path: "libMoltenVK.dylib"))
    try check(engine.lsfgShimDir == nil, "Missing real driver was reported available")
    try file(driver)
    try fm.removeItem(at: shim.appending(path: "libMoltenVK.dylib"))
    try fm.createDirectory(at: shim.appending(path: "libMoltenVK.dylib"), withIntermediateDirectories: false)
    try check(engine.lsfgShimDir == nil, "A directory was accepted as the shim")
    try fm.removeItem(at: shim.appending(path: "libMoltenVK.dylib"))
    try file(shim.appending(path: "libMoltenVK.dylib"))
    try check(engine.lsfgShimDir?.path == shim.path, "Driver link was not healed")
    let real = shim.appending(path: InstalledEngine.lsfgRealDriverName)
    try fm.removeItem(at: real)
    try fm.createSymbolicLink(atPath: real.path, withDestinationPath: "/missing-driver")
    try check(engine.lsfgShimDir?.path == shim.path, "Broken driver link was not healed")
    try fm.removeItem(at: real)
    try file(real, "keep this user file")
    _ = engine.lsfgShimDir
    let userFile = try String(contentsOf: real, encoding: .utf8)
    try check(userFile == "keep this user file", "Driver repair deleted a regular user file")

    let steam = bottle.driveC.appending(path: "Program Files (x86)/Steam")
    try file(steam.appending(path: "steam.exe"))
    let external = root.appending(path: "External Steam Library")
    let windowsLibrary = "Z:" + external.path.replacingOccurrences(of: "/", with: "\\")
    try file(steam.appending(path: "steamapps/libraryfolders.vdf"),
             "\"libraryfolders\" { \"1\" { \"path\" \"\(windowsLibrary.replacingOccurrences(of: "\\", with: "\\\\"))\" } }")
    let dll = external.appending(path: "steamapps/common/Custom LS/lsfg-vk.dll")
    try file(external.appending(path: "steamapps/appmanifest_993090.acf"),
             "\"AppState\" { \"appid\" \"993090\" \"name\" \"Lossless Scaling\" \"installdir\" \"Custom LS\" \"StateFlags\" \"4\" }")
    try file(dll)
    try check(bottle.losslessScalingDLL == dll, "Secondary Steam library was not discovered")
    var env = try bottle.environment(engine: engine, renderer: .dxvk,
        extra: ["LSFGVK_MULTIPLIER": "3", "DYLD_LIBRARY_PATH": "/custom/lib"])
    try check(env["LSFGVK_MULTIPLIER"] == "3", "Launch multiplier override was ignored")
    try check(env["DYLD_LIBRARY_PATH"] == shim.path + ":/custom/lib", "Shim priority or custom search path lost")
    try check(bottle.frameGenStatus(renderer: .dxvk, engine: engine, environment: env) == .active(multiplier: 3), "Status disagrees with environment")
    try check(WineRunner.launchHeader(engine: engine, bottle: bottle, renderer: .dxvk, env: env, args: []).contains("frameGen=3x(requested)"), "Header uses bottle value instead of launch multiplier")
    bottle.settings.environment["LSFGVK_DLL_PATH"] = "Z:" + dll.path.replacingOccurrences(of: "/", with: "\\")
    try check(bottle.losslessScalingDLL == dll, "Windows override was not translated")
    bottle.settings.environment["LSFGVK_DLL_PATH"] = external.path
    env = try bottle.environment(engine: engine, renderer: .dxvk)
    try check(env["LSFGVK_ENV"] == nil, "A directory was accepted as a shader DLL")
    try check(env["HB_LSFG_UNAVAILABLE"]?.contains("override") == true, "Invalid override was not explained")
    bottle.settings.environment.removeAll()
    env = try bottle.environment(engine: engine, renderer: .dxvk, extra: ["LSFGVK_MOLTENVK": driver.path])
    try check(env["LSFGVK_ENV"] == nil, "Recursive driver leaf name was accepted")
    env = try bottle.environment(engine: engine, renderer: .dxvk, extra: ["DISABLE_LSFGVK": "1"])
    try check(bottle.frameGenStatus(renderer: .dxvk, engine: engine, environment: env) == .off, "Explicit disable was ignored")
    for multiplier in [2, 3, 4] {
        bottle.settings.frameGen = multiplier
        env = try bottle.environment(engine: engine, renderer: .dxvk)
        try check(env["LSFGVK_MULTIPLIER"] == String(multiplier), "Supported multiplier not configured")
    }
    let dylib = shim.appending(path: "libMoltenVK.dylib").path
    env = try bottle.environment(engine: engine, renderer: .dxmt, extra: ["DYLD_INSERT_LIBRARIES": "/custom/insert.dylib"])
    try check(env["LSFGVK_ENV"] == "1" && env["LSFGVK_METAL"] == "1", "Metal renderer did not use the metal hook")
    try check(env["DYLD_INSERT_LIBRARIES"] == dylib + ":/custom/insert.dylib", "Metal hook not inserted ahead of custom libraries")
    try check(env["DYLD_LIBRARY_PATH"]?.hasPrefix(shim.path) == true, "Vulkan hook (D3D9 on a Metal renderer) missing")
    env = try bottle.environment(engine: engine, renderer: .wined3d, extra: ["WINE_D3D_CONFIG": "csmt=0,renderer=gl"])
    try check(env["LSFGVK_ENV"] == "1" && env["LSFGVK_METAL"] == nil, "WineD3D did not use the Vulkan hook")
    try check(env["WINE_D3D_CONFIG"] == "renderer=vulkan,csmt=0", "WineD3D was not switched to its Vulkan renderer")
    env = try bottle.environment(engine: engine, renderer: .dxvk, extra: ["LSFGVK_METAL": "1"])
    try check(env["LSFGVK_METAL"] == nil && env["DYLD_INSERT_LIBRARIES"] == nil, "Vulkan renderer picked up the metal hook")
    bottle.settings.frameGen = 1
    env = try bottle.environment(engine: engine, renderer: .dxvk, extra: ["LSFGVK_ENV": "1", "LSFGVK_MULTIPLIER": "3"])
    try check(env["LSFGVK_ENV"] == nil && env["DISABLE_LSFGVK"] == "1", "Off setting was bypassed by an override")
    env = try bottle.environment(engine: engine, renderer: .dxmt, extra: ["LSFGVK_METAL": "1"])
    try check(env["LSFGVK_METAL"] == nil && env["DISABLE_LSFGVK"] == "1", "Off setting left the metal hook armed")
    for value in [-1, 0, 999] {
        let settings = try JSONDecoder.highball.decode(BottleSettings.self,
            from: Data("{\"name\":\"old\",\"engineID\":\"e\",\"frameGen\":\(value)}".utf8))
        try check(settings.frameGen == 1, "Invalid saved multiplier did not default to off")
    }
    let legacy = try JSONDecoder.highball.decode(BottleSettings.self, from: Data(#"{"name":"old","engineID":"e"}"#.utf8))
    try check(legacy.frameGen == 1, "Legacy bottle did not default to off")
    try fm.removeItem(at: driver)
    try check(engine.lsfgShimDir == nil, "Removed driver was reported available")
}

private func localComponentChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "hb-local-component-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let archive = root.appending(path: "component.tar.xz")
    let bytes = Data("local archive fixture".utf8)
    try bytes.write(to: archive)
    let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    var component = EngineManifest.Component(kind: "renderer", url: archive, sha256: sha.uppercased())
    let store = EngineStore(paths: HighballPaths(home: root.appending(path: "home")))
    let fetched = try await store.download(component, name: "local")
    guard fetched == archive else { throw HighballError.failed("Local component did not preserve its URL") }
    component.sha256 = String(repeating: "0", count: 64)
    do {
        _ = try await store.download(component, name: "local")
        throw HighballError.failed("Local component bypassed checksum validation")
    } catch HighballError.checksumMismatch { }
}

#if FRAMEGEN_STANDALONE
@main enum FrameGenerationChecks {
    static func main() async throws { try frameGenerationChecks(); try await localComponentChecks(); print("Frame generation integration checks passed") }
}
#else
import XCTest
final class FrameGenerationTests: XCTestCase {
    func testLaunchConfigurationAndRecovery() throws { try frameGenerationChecks() }
    func testLocalComponentChecksums() async throws { try await localComponentChecks() }
}
#endif
