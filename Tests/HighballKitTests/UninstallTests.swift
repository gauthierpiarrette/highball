import XCTest
@testable import HighballKit

/// highball#185, asked on r/macgaming: there was no way to remove a game from its page. The rule
/// these tests hold to is that a store's library is the store's to keep, so Highball never deletes
/// a Steam or Epic game's files itself.
final class UninstallTests: XCTestCase {
    private func item(_ source: HighballKit.LibrarySource, steam: Int? = nil, epic: String? = nil, size: Int64 = 0) -> HighballKit.LibraryItem {
        HighballKit.LibraryItem(source: source, id: "x", title: "Portal 2", bottleName: "Games", installed: true,
                    steamAppID: steam, epicAppName: epic, sizeOnDisk: size)
    }

    func testASteamGameIsHandedToSteam() {
        XCTAssertEqual(Uninstall.route(for: item(.steam, steam: 620)), .steam(appID: 620))
        XCTAssertEqual(Uninstall.steamURL(appID: 620), "steam://uninstall/620",
                       "the client shows its own dialog and does the removing")
    }

    func testAnEpicGameIsHandedToTheEpicTools() {
        XCTAssertEqual(Uninstall.route(for: item(.epic, epic: "Fortnite")), .epic(appName: "Fortnite"))
        XCTAssertEqual(EpicStore.uninstallArguments(appName: "Fortnite"), ["uninstall", "Fortnite", "-y"])
    }

    func testAPinnedProgramGoesThroughWindowsAddRemove() {
        XCTAssertEqual(Uninstall.route(for: item(.pin)), .windowsUninstaller)
    }

    /// A store entry with no id cannot be handed anywhere, and offering a button whose only
    /// outcome is nothing happening is worse than saying so.
    func testAStoreEntryWithoutAnIdSaysSoInsteadOfOfferingAButton() {
        for route in [Uninstall.route(for: item(.steam)), Uninstall.route(for: item(.epic))] {
            guard case let .none(reason) = route else { return XCTFail("expected none, got \(route)") }
            XCTAssertFalse(Uninstall.isActionable(route))
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertTrue(Uninstall.isActionable(.steam(appID: 1)))
        XCTAssertTrue(Uninstall.isActionable(.windowsUninstaller))
    }

    func testTheQuestionNamesWhoRemovesItAndWhatComesBack() {
        let steam = Uninstall.confirmation(title: "Portal 2", route: .steam(appID: 620), sizeOnDisk: 12_884_901_888)
        XCTAssertTrue(steam.contains("Portal 2"), steam)
        XCTAssertTrue(steam.contains("Steam does the uninstalling"), steam)
        XCTAssertTrue(steam.contains("GB"), "a confirmation without a figure is unanswerable: \(steam)")
        let unknownSize = Uninstall.confirmation(title: "Portal 2", route: .steam(appID: 620), sizeOnDisk: 0)
        XCTAssertFalse(unknownSize.contains("frees"), "no invented figure when the size is unknown")
    }

    /// The Windows route can come up empty, and the question says so rather than promising.
    func testTheWindowsRouteAdmitsItMayNotListTheGame() {
        let text = Uninstall.confirmation(title: "Dark Omen", route: .windowsUninstaller, sizeOnDisk: 0)
        XCTAssertTrue(text.contains("will not be in that list"), text)
        XCTAssertTrue(text.contains("delete the environment"), text)
    }

    func testTheReasonIsWhatAnUnroutableGameShows() {
        let route = Uninstall.route(for: item(.steam))
        guard case let .none(reason) = route else { return XCTFail("expected none") }
        XCTAssertEqual(Uninstall.confirmation(title: "Portal 2", route: route, sizeOnDisk: 99), reason,
                       "no size talk when nothing can be removed")
    }
}
