import XCTest
@testable import HighballKit

final class SteamAccountsTests: XCTestCase {
    /// Two made-up accounts as Steam writes them; the second signed in last.
    let loginUsers = """
    "users"
    {
    \t"76561198000000001"
    \t{
    \t\t"AccountName"\t\t"signin-one"
    \t\t"PersonaName"\t\t"Alder"
    \t\t"RememberPassword"\t\t"1"
    \t\t"Timestamp"\t\t"1790000000"
    \t}
    \t"76561198000000002"
    \t{
    \t\t"AccountName"\t\t"signin-two"
    \t\t"PersonaName"\t\t"Birch"
    \t\t"timestamp"\t\t"1790000500"
    \t}
    }
    """

    func testAccountsAreKnownByDisplayNameNewestFirst() {
        let accounts = SteamAccounts.parse(loginUsers: loginUsers)
        XCTAssertEqual(accounts.map(\.displayName), ["Birch", "Alder"])
        XCTAssertEqual(accounts.map(\.id), [76561198000000002, 76561198000000001])
    }

    /// The sign-in name is half of what signs in: an account keeps its ID, profile name and last
    /// sign-in, and a field added to it later fails here until it is looked at.
    func testAnAccountKeepsNoSignInName() {
        let account = SteamAccounts.parse(loginUsers: loginUsers)[0]
        XCTAssertEqual(Mirror(reflecting: account).children.compactMap(\.label), ["id", "displayName", "lastSignIn"])
        XCTAssertFalse(String(describing: account).contains("signin-"))
    }

    /// Braces and escaped quotes in a profile name, and a block nested in a user's: still read.
    func testProfileNamesWithBracesAndQuotes() {
        let text = #"""
        "users" { "76561198000000003" { "AccountName" "x" "PersonaName" "a {\"b\"} c" "Timestamp" "5" "extra" { "k" "v" } } }
        """#
        XCTAssertEqual(SteamAccounts.parse(loginUsers: text).map(\.displayName), [#"a {"b"} c"#])
    }

    func testActiveUserComesFromTheRegistry() {
        XCTAssertEqual(SteamAccounts.activeUser(inRegistry: "[Software\\\\Valve\\\\Steam\\\\ActiveProcess]\n\"ActiveUser\"=dword:023c3462\n"),
                       76561197960265728 + 0x023c3462)
        XCTAssertNil(SteamAccounts.activeUser(inRegistry: "\"ActiveUser\"=dword:00000000\n"), "0: no account")
        XCTAssertNil(SteamAccounts.activeUser(inRegistry: ""))
    }

    func testInstallRecordsNameTheAccountThatInstalled() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "appmanifest_\(UUID().uuidString).acf")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        "AppState"
        {
        \t"appid"\t\t"1392860"
        \t"name"\t\t"Some Game"
        \t"StateFlags"\t\t"4"
        \t"LastOwner"\t\t"76561198000000001"
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SteamLibrary.parseManifest(file)?.lastOwner, 76561198000000001)
        try "\"AppState\" { \"appid\" \"1\" \"name\" \"X\" \"LastOwner\" \"0\" }".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(SteamLibrary.parseManifest(file)?.lastOwner)
    }

    func testGameNoteWarnsOnlyWhenAnotherAccountIsSignedIn() {
        let accounts = SteamAccounts.parse(loginUsers: loginUsers)
        let alder: UInt64 = 76561198000000001, birch: UInt64 = 76561198000000002
        // Another account signed in now.
        let other = SteamAccounts.note(installedBy: alder, accounts: accounts, activeUser: birch, steamRunning: true)
        XCTAssertEqual(other?.installedBy.displayName, "Alder")
        XCTAssertEqual(other?.otherAccount?.displayName, "Birch")
        XCTAssertEqual(other?.signedInNow, true)
        // The installer is signed in: the row, no warning.
        XCTAssertNil(SteamAccounts.note(installedBy: alder, accounts: accounts, activeUser: alder, steamRunning: true)?.otherAccount)
        // Steam not running, ActiveUser 0: the account it signed in to last, loginusers.vdf's newest.
        let closed = SteamAccounts.note(installedBy: alder, accounts: accounts, activeUser: nil, steamRunning: false)
        XCTAssertEqual(closed?.otherAccount?.displayName, "Birch")
        XCTAssertEqual(closed?.signedInNow, false)
        // Nothing to say: one account on this Steam, or no record of who installed it.
        XCTAssertNil(SteamAccounts.note(installedBy: alder, accounts: [accounts[1]], activeUser: nil, steamRunning: false))
        XCTAssertNil(SteamAccounts.note(installedBy: nil, accounts: accounts, activeUser: birch, steamRunning: true))
        XCTAssertNil(SteamAccounts.note(installedBy: 76561198000000009, accounts: accounts, activeUser: birch, steamRunning: true))
    }

    /// ActiveUser can stay set after Steam quits: with Steam closed it is who signed in last,
    /// never "is signed in".
    func testActiveUserLeftBehindIsTheLastSignInOnly() {
        let accounts = SteamAccounts.parse(loginUsers: loginUsers)
        let alder: UInt64 = 76561198000000001, birch: UInt64 = 76561198000000002
        let left = SteamAccounts.note(installedBy: alder, accounts: accounts, activeUser: birch, steamRunning: false)
        XCTAssertEqual(left?.otherAccount?.displayName, "Birch")
        XCTAssertEqual(left?.signedInNow, false)
        // Running at the sign-in screen, nobody active yet: still only the last sign-in.
        XCTAssertEqual(SteamAccounts.note(installedBy: alder, accounts: accounts, activeUser: nil, steamRunning: true)?.signedInNow, false)
    }

    /// The player's own answer to whose a game is decides whom the warning is about.
    func testGameNoteGoesByThePlayersChoice() {
        let accounts = SteamAccounts.parse(loginUsers: loginUsers)
        let alder: UInt64 = 76561198000000001, birch: UInt64 = 76561198000000002
        XCTAssertNil(SteamAccounts.note(installedBy: alder, accounts: accounts, activeUser: birch, steamRunning: true,
                                        owners: [birch])?.otherAccount, "the player says the signed-in account has it")
        XCTAssertNil(SteamAccounts.note(installedBy: alder, accounts: accounts, activeUser: birch, steamRunning: true,
                                        owners: [alder, birch])?.otherAccount, "Every account here")
        XCTAssertEqual(SteamAccounts.note(installedBy: alder, accounts: accounts, activeUser: alder, steamRunning: true,
                                          owners: [birch])?.otherAccount?.displayName, "Alder",
                       "the player says only the other account has it")
        XCTAssertEqual(SteamAccounts.note(installedBy: alder, accounts: accounts, activeUser: birch, steamRunning: true,
                                          owners: [])?.otherAccount?.displayName, "Birch", "an empty choice is no choice")
    }

    /// The player's choice wins; otherwise every account with a sign, the strongest named.
    func testOwnersComeFromTheChoiceElseEverySign() {
        let alder: UInt64 = 76561198000000001, birch: UInt64 = 76561198000000002
        let both: Set<UInt64> = [alder, birch]
        XCTAssertEqual(SteamAccounts.owners(appID: 7, installedBy: alder, added: [7: birch], chosen: [:], present: both),
                       SteamAccounts.Owners(accounts: [alder, birch], reason: .installed))
        XCTAssertEqual(SteamAccounts.owners(appID: 9, installedBy: nil, added: [9: alder], chosen: [:], present: both),
                       SteamAccounts.Owners(accounts: [alder], reason: .added))
        XCTAssertEqual(SteamAccounts.owners(appID: 7, installedBy: alder, added: [:], chosen: [7: [birch]], present: both),
                       SteamAccounts.Owners(accounts: [birch], reason: .chosen))
    }

    /// No sign of whose a game is (it arrived before Highball first looked, or its install record
    /// says LastOwner 0): every account's, so no account's filter drops it and its page can set it.
    func testAGameWithNoSignIsAnyAccounts() {
        let alder: UInt64 = 76561198000000001, birch: UInt64 = 76561198000000002
        XCTAssertEqual(SteamAccounts.owners(appID: 10, installedBy: nil, added: [:], chosen: [:], present: [alder, birch]),
                       SteamAccounts.Owners(accounts: [alder, birch], reason: .unknown))
        XCTAssertEqual(SteamAccounts.owners(appID: 10, installedBy: nil, added: [11: alder], chosen: [11: [birch]], present: [alder, birch]),
                       SteamAccounts.Owners(accounts: [alder, birch], reason: .unknown), "another game's signs are not this one's")
    }

    /// An account that has left loginusers.vdf counts for nothing: a choice of it gives way to the
    /// signs, a sign of it to the others, and a game left with none is any account's.
    func testAnAccountThatLeftTrapsNoGame() {
        let alder: UInt64 = 76561198000000001, birch: UInt64 = 76561198000000002, gone: UInt64 = 76561198000000009
        let present: Set<UInt64> = [alder, birch]
        XCTAssertEqual(SteamAccounts.owners(appID: 7, installedBy: alder, added: [:], chosen: [7: [gone]], present: present),
                       SteamAccounts.Owners(accounts: [alder], reason: .installed), "the choice gives way to the signs")
        XCTAssertEqual(SteamAccounts.owners(appID: 7, installedBy: nil, added: [:], chosen: [7: [gone, birch]], present: present),
                       SteamAccounts.Owners(accounts: [birch], reason: .chosen), "what is left of the choice stands")
        XCTAssertEqual(SteamAccounts.owners(appID: 7, installedBy: gone, added: [7: birch], chosen: [:], present: present),
                       SteamAccounts.Owners(accounts: [birch], reason: .added), "the reason is a present account's")
        XCTAssertEqual(SteamAccounts.owners(appID: 7, installedBy: gone, added: [7: gone], chosen: [7: [gone]], present: present),
                       SteamAccounts.Owners(accounts: present, reason: .unknown))
        XCTAssertEqual(SteamAccounts.owners(appID: 7, installedBy: alder, added: [:], chosen: [7: []], present: present),
                       SteamAccounts.Owners(accounts: [alder], reason: .installed), "an empty choice is no choice")
    }

    /// Each account's first sign-in is when Steam made its userdata folder, named by the 32-bit
    /// account ID; other folders there are no account's.
    func testFirstSignInsComeFromTheUserdataFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-accounts-\(UUID())/Steam")
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let userdata = root.appending(path: "userdata")
        let first = Date(timeIntervalSince1970: 1_600_000_000), second = Date(timeIntervalSince1970: 1_600_086_400)
        for (folder, made) in [("39734273", first), ("39734274", second), ("anonymous", first)] {
            let url = userdata.appending(path: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.creationDate: made], ofItemAtPath: url.path)
        }
        let signIns = SteamAccounts.firstSignIns(steamRoot: root)
        XCTAssertEqual(Set(signIns.keys), [SteamAccounts.steamIDBase + 39734273, SteamAccounts.steamIDBase + 39734274])
        XCTAssertEqual(signIns[SteamAccounts.steamIDBase + 39734273]?.timeIntervalSince1970 ?? 0, first.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(signIns[SteamAccounts.steamIDBase + 39734274]?.timeIntervalSince1970 ?? 0, second.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(SteamAccounts.firstSignIns(steamRoot: root.appending(path: "nowhere")), [:], "no userdata: nobody")
    }

    /// Games that appeared while only the first account had ever signed in are its; later ones
    /// are nobody's here until seen arriving.
    func testGamesFromBeforeASecondAccountAreTheFirstOnes() {
        let alder: UInt64 = 76561198000000001, birch: UInt64 = 76561198000000002
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let signIns = [alder: t, birch: t.addingTimeInterval(86_400)]
        let appeared = [1: t.addingTimeInterval(60), 2: t.addingTimeInterval(3_600), 3: t.addingTimeInterval(90_000)]
        XCTAssertEqual(SteamAccounts.earlyArrivals(appeared, firstSignIns: signIns), [1: alder, 2: alder])
        XCTAssertEqual(SteamAccounts.earlyArrivals(appeared, firstSignIns: [alder: t]), [1: alder, 2: alder, 3: alder], "one account: all its")
        XCTAssertEqual(SteamAccounts.earlyArrivals(appeared, firstSignIns: [:]), [:])
    }

    /// Comments and escaped backslashes, as real files hold them; keys matched without case.
    func testCommentsEscapesAndKeyCase() {
        let text = #"""
        // written by Steam
        "Users" { "76561198000000004" { "PERSONANAME" "C:\\Games" "Timestamp" "7" } }
        """#
        XCTAssertEqual(SteamAccounts.parse(loginUsers: text).map(\.displayName), [#"C:\Games"#])
    }

    /// A game first seen is put down to the account signed in; the first look only notes.
    func testArrivalsArePutDownToTheSignedInAccount() {
        var seen = Set<Int>(), added = [Int: UInt64]()
        XCTAssertTrue(SteamAccounts.noteArrivals([1, 2], signedIn: 9, firstLook: true, seen: &seen, added: &added))
        XCTAssertEqual(added, [:], "already there before Highball looked: arrival unknown")
        XCTAssertTrue(SteamAccounts.noteArrivals([1, 2, 3], signedIn: 9, firstLook: false, seen: &seen, added: &added))
        XCTAssertEqual(added, [3: 9])
        XCTAssertFalse(SteamAccounts.noteArrivals([3], signedIn: 8, firstLook: false, seen: &seen, added: &added))
        XCTAssertEqual(added, [3: 9], "a game is put down once")
        SteamAccounts.noteArrivals([4], signedIn: nil, firstLook: false, seen: &seen, added: &added)
        XCTAssertNil(added[4], "nobody known signed in")
        XCTAssertTrue(seen.contains(4))
    }
}
