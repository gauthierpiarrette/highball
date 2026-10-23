import XCTest
@testable import HighballKit

/// A program started from outside the app (`highball run <bottle> <program>`, a launcher driving
/// the CLI) runs with the mode Play would give it: the one asked for, then the mode chosen on its
/// game page, then its own, then the environment's.
final class PinOutsideLaunchTests: XCTestCase {
    private func settings(_ renderer: Renderer, explicit: Bool = false) -> BottleSettings {
        var s = BottleSettings(name: "Games", engineID: "test-engine")
        s.renderer = renderer
        s.rendererExplicit = explicit
        return s
    }

    func testTheGamePagesModeWinsOverTheProgramsOwnAndTheEnvironments() {
        let pin = Pin(name: "9 Kings", path: "/Games/9 Kings/9Kings.exe", renderer: .dxvk)
        let launched = pin.launching(requested: nil, gameOverride: .dxmt, in: settings(.wined3d, explicit: true))
        XCTAssertEqual(launched.renderer, .dxmt)
    }

    func testAModeAskedForWinsOverTheGamePage() {
        let pin = Pin(name: "9 Kings", path: "/Games/9 Kings/9Kings.exe")
        XCTAssertEqual(pin.launching(requested: .d3dmetal, gameOverride: .dxmt, in: settings(.dxmt)).renderer, .d3dmetal)
    }

    func testWithoutAChoiceTheProgramsOwnThenTheEnvironmentsModeIsUsed() {
        let own = Pin(name: "A", path: "/a.exe", renderer: .dxvk)
        XCTAssertEqual(own.launching(requested: nil, gameOverride: nil, in: settings(.dxmt)).renderer, .dxvk)
        let plain = Pin(name: "B", path: "/b.exe")
        XCTAssertEqual(plain.launching(requested: nil, gameOverride: nil, in: settings(.dxmt)).renderer, .dxmt)
    }

    func testTheLibraryIDNamesTheEnvironmentAndTheProgram() {
        let pin = Pin(name: "A", path: "/a.exe")
        XCTAssertEqual(pin.libraryID(in: "Games"), "pin:Games:\(pin.id.uuidString)")
    }
}
