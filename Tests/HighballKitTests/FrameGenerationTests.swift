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
    let manifest = EngineManifest(id: "framegen-test", displayName: "Frame generation test",
                                  arch: "x86_64", minMacOS: "14.0", components: [:])
    let engine = InstalledEngine(manifest: manifest, root: root.appending(path: "engine"))
    var bottle = Bottle(url: root.appending(path: "bottle"), settings: BottleSettings(name: "audit", engineID: manifest.id))
    for renderer in ["dxvk", "d9vk", "dxmt", "vkd3d"] {
        try fm.createDirectory(at: engine.renderersDir.appending(path: "\(renderer)/wine"), withIntermediateDirectories: true)
    }
    bottle.settings.frameGen = 2
    let shim = engine.renderersDir.appending(path: "lsfg")
    let driver = engine.frameworksDir.appending(path: "libMoltenVK.dylib")
    try file(shim.appending(path: "libMoltenVK.dylib"))
    try check(engine.resolveLsfgShimDir() == nil, "Missing real driver was reported available")
    try file(driver)
    try fm.removeItem(at: shim.appending(path: "libMoltenVK.dylib"))
    try fm.createDirectory(at: shim.appending(path: "libMoltenVK.dylib"), withIntermediateDirectories: false)
    try check(engine.resolveLsfgShimDir() == nil, "A directory was accepted as the shim")
    try fm.removeItem(at: shim.appending(path: "libMoltenVK.dylib"))
    try file(shim.appending(path: "libMoltenVK.dylib"))
    try check(engine.resolveLsfgShimDir()?.path == shim.path, "Driver link was not healed")
    let real = shim.appending(path: InstalledEngine.lsfgRealDriverName)
    try fm.removeItem(at: real)
    try fm.createSymbolicLink(atPath: real.path, withDestinationPath: "/missing-driver")
    try check(engine.resolveLsfgShimDir()?.path == shim.path, "Broken driver link was not healed")
    try fm.removeItem(at: real)
    try file(real, "keep this user file")
    _ = engine.resolveLsfgShimDir()
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
        extra: ["LSFGM_MULTIPLIER": "3", "DYLD_LIBRARY_PATH": "/custom/lib"])
    try check(env["LSFGM_MULTIPLIER"] == "3", "Launch multiplier override was ignored")
    try check(env["DYLD_LIBRARY_PATH"] == shim.path + ":/custom/lib", "Shim priority or custom search path lost")
    try check(bottle.frameGenStatus(engine: engine, environment: env) == .active(multiplier: 3), "Status disagrees with environment")
    try check(bottle.frameGenStatus(shim: shim, environment: env) == .active(multiplier: 3), "Cached shim status disagrees")
    try check(bottle.frameGenStatus(shim: nil, environment: env) == .unavailable("This engine has no usable frame generation component. Build or install the component for this engine."), "Missing cached shim was reported active")
    try check(WineRunner.launchHeader(engine: engine, bottle: bottle, renderer: .dxvk, env: env, args: []).contains("frameGen=3x(requested)"), "Header uses bottle value instead of launch multiplier")
    bottle.settings.environment["LSFGM_DLL_PATH"] = "Z:" + dll.path.replacingOccurrences(of: "/", with: "\\")
    try check(bottle.losslessScalingDLL == dll, "Windows override was not translated")
    bottle.settings.environment["LSFGM_DLL_PATH"] = external.path
    env = try bottle.environment(engine: engine, renderer: .dxvk)
    try check(env["LSFGM_ENV"] == nil, "A directory was accepted as a shader DLL")
    try check(env["HB_LSFG_UNAVAILABLE"]?.contains("override") == true, "Invalid override was not explained")
    bottle.settings.environment.removeAll()
    env = try bottle.environment(engine: engine, renderer: .dxvk, extra: ["LSFGM_MOLTENVK": driver.path])
    try check(env["LSFGM_ENV"] == nil, "Recursive driver leaf name was accepted")
    env = try bottle.environment(engine: engine, renderer: .dxvk, extra: ["DISABLE_LSFGM": "1"])
    try check(bottle.frameGenStatus(engine: engine, environment: env) == .off, "Explicit disable was ignored")
    for multiplier in [2, 3, 4] {
        bottle.settings.frameGen = multiplier
        env = try bottle.environment(engine: engine, renderer: .dxvk)
        try check(env["LSFGM_MULTIPLIER"] == String(multiplier), "Supported multiplier not configured")
    }
    try check(env["LSFGM_PACING_MODE"] == "vsync", "Default pacing is not fixed vsync")
    try check(env["LSFGM_FLOW_SCALE"] == nil, "Full flow scale was exported")
    try check(env["LSFGM_PERFORMANCE_MODE"] == nil, "Performance mode exported by default")
    try check(env["LSFGM_OVERRIDE_PRESENT_MODE"] == nil, "Present-mode override exported while forcing vsync")
    bottle.settings.frameGenForceVsync = false
    env = try bottle.environment(engine: engine, renderer: .dxvk)
    try check(env["LSFGM_OVERRIDE_PRESENT_MODE"] == "0", "Turning off forced vsync did not release the present mode")
    bottle.settings.frameGenForceVsync = true
    env = try bottle.environment(engine: engine, renderer: .dxvk)
    try check(env["LSFGM_OVERRIDE_PRESENT_MODE"] == nil, "Forced vsync did not return to the default")
    let vsyncDefault = try JSONDecoder.highball.decode(BottleSettings.self, from: Data(#"{"name":"old","engineID":"e"}"#.utf8))
    try check(vsyncDefault.frameGenForceVsync, "A bottle saved before this setting existed did not default to forcing vsync")
    bottle.settings.frameGenAdaptive = true
    bottle.settings.frameGenFlowScale = 50
    bottle.settings.frameGenPerformance = true
    env = try bottle.environment(engine: engine, renderer: .dxvk)
    try check(env["LSFGM_PACING_MODE"] == "adaptive" && env["LSFGM_FLOW_SCALE"] == "0.50" && env["LSFGM_PERFORMANCE_MODE"] == "1", "Adaptive, flow and performance settings not configured")
    try check(WineRunner.launchHeader(engine: engine, bottle: bottle, renderer: .dxvk, env: env, args: []).contains("frameGen=4x(requested, adaptive, flow 0.50, performance)"), "Header omits pacing, flow and performance")
    let flowSettings = try JSONDecoder.highball.decode(BottleSettings.self, from: Data(#"{"name":"old","engineID":"e","frameGenFlowScale":10}"#.utf8))
    try check(flowSettings.frameGenFlowScale == 100, "Invalid saved flow scale did not default to full")
    env = try bottle.environment(engine: engine, renderer: .dxvk, extra: ["LSFGM_PACING_MODE": "vsync"])
    try check(env["LSFGM_PACING_MODE"] == "vsync", "Pacing override was replaced")
    bottle.settings.frameGenAdaptive = false
    bottle.settings.frameGenFlowScale = 100
    bottle.settings.frameGenPerformance = false
    bottle.settings.fpsCap = 30
    env = try bottle.environment(engine: engine, renderer: .dxmt) // the test engine has no d3dmetal
    try check(env["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=30;", "Frame cap not passed to dxmt")
    bottle.settings.fpsCap = 0
    let dylib = shim.appending(path: "libMoltenVK.dylib").path
    env = try bottle.environment(engine: engine, renderer: .dxmt, extra: ["DYLD_INSERT_LIBRARIES": "/custom/insert.dylib"])
    try check(env["LSFGM_ENV"] == "1" && env["LSFGM_METAL"] == "1", "Metal renderer did not use the metal hook")
    try check(env["DYLD_INSERT_LIBRARIES"] == dylib + ":/custom/insert.dylib", "Metal hook not inserted ahead of custom libraries")
    try check(env["DYLD_LIBRARY_PATH"]?.hasPrefix(shim.path) == true, "Vulkan hook (D3D9 on a Metal renderer) missing")
    env = try bottle.environment(engine: engine, renderer: .wined3d, extra: ["WINE_D3D_CONFIG": "csmt=0,renderer=gl"])
    try check(env["LSFGM_ENV"] == "1" && env["LSFGM_METAL"] == nil && env["LSFGM_OPENGL"] == "1", "WineD3D did not use the Vulkan and OpenGL hooks")
    try check(env["WINE_D3D_CONFIG"] == "csmt=0,renderer=gl", "WineD3D OpenGL override was replaced")
    try check(env["DYLD_INSERT_LIBRARIES"] == dylib, "WineD3D OpenGL hook was not inserted")
    env = try bottle.environment(engine: engine, renderer: .wined3d, extra: ["WINE_D3D_CONFIG": "renderer=vulkan,csmt=0"])
    try check(env["WINE_D3D_CONFIG"] == "renderer=vulkan,csmt=0", "WineD3D Vulkan override was replaced")
    env = try bottle.environment(engine: engine, renderer: .wined3d)
    try check(env["WINE_D3D_CONFIG"] == nil, "Frame generation forced a WineD3D renderer")
    env = try bottle.environment(engine: engine, renderer: .dxvk, extra: ["LSFGM_METAL": "1"])
    try check(env["LSFGM_METAL"] == nil && env["LSFGM_OPENGL"] == "1" && env["DYLD_INSERT_LIBRARIES"] == dylib, "Vulkan renderer picked up the metal hook or lost the OpenGL one")
    bottle.settings.frameGen = 1
    env = try bottle.environment(engine: engine, renderer: .dxvk, extra: ["LSFGM_ENV": "1", "LSFGM_MULTIPLIER": "3"])
    try check(env["LSFGM_ENV"] == nil && env["DISABLE_LSFGM"] == "1", "Off setting was bypassed by an override")
    env = try bottle.environment(engine: engine, renderer: .dxmt, extra: ["LSFGM_METAL": "1", "LSFGM_OPENGL": "1"])
    try check(env["LSFGM_METAL"] == nil && env["LSFGM_OPENGL"] == nil && env["DISABLE_LSFGM"] == "1", "Off setting left a hook armed")
    for value in [-1, 0, 999] {
        let settings = try JSONDecoder.highball.decode(BottleSettings.self,
            from: Data("{\"name\":\"old\",\"engineID\":\"e\",\"frameGen\":\(value)}".utf8))
        try check(settings.frameGen == 1, "Invalid saved multiplier did not default to off")
    }
    let legacy = try JSONDecoder.highball.decode(BottleSettings.self, from: Data(#"{"name":"old","engineID":"e"}"#.utf8))
    try check(legacy.frameGen == 1, "Legacy bottle did not default to off")
    try fm.removeItem(at: driver)
    try check(engine.resolveLsfgShimDir() == nil, "Removed driver was reported available")
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
