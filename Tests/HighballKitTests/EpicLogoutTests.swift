import XCTest
@testable import HighballKit

/// Disconnecting Epic always leaves the player signed out (highball#708): legendary's own
/// `auth --delete` when it runs, and the user.json `isAuthenticated` reads either way.
final class EpicLogoutTests: XCTestCase {
    private var home: URL!
    private var store: EpicStore { EpicStore(paths: HighballPaths(home: home)) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "epic-logout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: "legendary"), withIntermediateDirectories: true)
        try #"{"displayName":"player"}"#.write(to: home.appending(path: "legendary/user.json"), atomically: true, encoding: .utf8)
    }
    override func tearDown() { if let home { try? FileManager.default.removeItem(at: home) } }

    func testWithoutLegendaryTheAccountStillGoes() {
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertThrowsError(try store.logout(), "no legendary binary in this home")
        XCTAssertFalse(store.isAuthenticated, "user.json must go even when legendary can't run")
    }

    func testALegendaryThatLeavesTheFileStillSignsOut() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else { throw XCTSkip("needs /bin/sh") }
        let tools = home.appending(path: "tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        // A legendary that answers and deletes nothing, as one whose session check failed might.
        try "#!/bin/sh\nexit 0\n".write(to: tools.appending(path: "legendary"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools.appending(path: "legendary").path)
        XCTAssertNoThrow(try store.logout())
        XCTAssertFalse(store.isAuthenticated)
    }
}
