import XCTest
import Darwin
@testable import HighballKit

final class WineReparsePointTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "reparse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// A REPARSE_DATA_BUFFER as Windows lays it out: header, the name offsets, then the
    /// substitute and print names back to back in UTF-16LE.
    static func blob(tag: UInt32, substitute: String, relative: Bool) -> Data {
        let name = Array(substitute.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let subLen = name.count, printOff = subLen + 2
        var body: [UInt8] = []
        func u16(_ v: Int) { body += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) { body += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        u16(0); u16(subLen); u16(printOff); u16(subLen)
        if tag == 0xA000_000C { u32(relative ? 1 : 0) }
        body += name + [0, 0] + name + [0, 0]
        var out: [UInt8] = []
        out += [UInt8(tag & 0xFF), UInt8(tag >> 8 & 0xFF), UInt8(tag >> 16 & 0xFF), UInt8(tag >> 24)]
        out += [UInt8(body.count & 0xFF), UInt8(body.count >> 8), 0, 0]
        return Data(out + body)
    }

    /// The bytes Wine 11 (CrossOver 26.3) wrote for the EA app installer's `EA Desktop\EA Desktop`
    /// junction, read back from the bottle with `xattr -p -x user.WINEREPARSE`.
    static let eaJunctionHex = "0C0000A070000000000030003200300001000000"
        + "310033002E003700380033002E0030002E0036003200390036005C004500410020004400650073006B0074006F00700000"
        + "00310033002E003700380033002E0030002E0036003200390036005C004500410020004400650073006B0074006F0070000000"

    /// Makes a stub the way Wine does: an empty directory carrying the attribute.
    func makeStub(in dir: URL, name: String, data: Data) throws {
        let stub = dir.appending(path: name)
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        let rc = data.withUnsafeBytes { setxattr(stub.path, WineReparsePoint.attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        XCTAssertEqual(rc, 0, "setxattr failed: \(String(cString: strerror(errno)))")
    }

    /// EA's layout: the versioned folder holds the client, the unversioned name is the link.
    func makeEAInstall(under base: URL, stubName: String = "EA Desktop?") throws -> (dir: URL, exe: URL) {
        let dir = base.appending(path: "Program Files/Electronic Arts/EA Desktop")
        let versioned = dir.appending(path: "13.783.0.6296/EA Desktop")
        try FileManager.default.createDirectory(at: versioned, withIntermediateDirectories: true)
        let exe = versioned.appending(path: "EADesktop.exe")
        try Data("MZ".utf8).write(to: exe)
        try makeStub(in: dir, name: stubName, data: Self.blob(tag: 0xA000_000C, substitute: "13.783.0.6296\\EA Desktop", relative: true))
        return (dir, exe)
    }

    // MARK: Decoding

    func testDecodesRelativeSymlinkAndAbsoluteJunction() {
        let sym = WineReparsePoint.decode(Self.blob(tag: 0xA000_000C, substitute: "13.783.0.6296\\EA Desktop", relative: true))
        XCTAssertEqual(sym, .init(tag: 0xA000_000C, target: "13.783.0.6296\\EA Desktop", isRelative: true))
        let junction = WineReparsePoint.decode(Self.blob(tag: 0xA000_0003, substitute: "\\??\\C:\\Program Files\\X\\1.0", relative: false))
        XCTAssertEqual(junction, .init(tag: 0xA000_0003, target: "\\??\\C:\\Program Files\\X\\1.0", isRelative: false))
        XCTAssertNil(WineReparsePoint.decode(Self.blob(tag: 0x8000_0017, substitute: "x", relative: false)), "other tags name no target")
        XCTAssertNil(WineReparsePoint.decode(Data([1, 2, 3])))
    }

    func testDecodesTheBytesWineActuallyWrote() {
        var bytes: [UInt8] = []
        var hex = Substring(Self.eaJunctionHex)
        while hex.count >= 2 { bytes.append(UInt8(hex.prefix(2), radix: 16)!); hex = hex.dropFirst(2) }
        let d = WineReparsePoint.decode(Data(bytes))
        XCTAssertEqual(d?.tag, 0xA000_000C)
        XCTAssertEqual(d?.isRelative, true)
        XCTAssertEqual(d?.target, "13.783.0.6296\\EA Desktop")
    }

    func testHostTargets() {
        let driveC = root.appending(path: "drive_c"), parent = driveC.appending(path: "Program Files/Vendor")
        let rel = WineReparsePoint.hostTarget(.init(tag: 0, target: "1.0\\App", isRelative: true), stubParent: parent, driveC: driveC)
        XCTAssertEqual(rel?.path, parent.appending(path: "1.0/App").path)
        let abs = WineReparsePoint.hostTarget(.init(tag: 0, target: "\\??\\C:\\Program Files\\Vendor\\1.0\\App", isRelative: false), stubParent: parent, driveC: driveC)
        XCTAssertEqual(abs?.path, driveC.appending(path: "Program Files/Vendor/1.0/App").path)
        let z = WineReparsePoint.hostTarget(.init(tag: 0, target: "Z:\\Users\\me\\x", isRelative: false), stubParent: parent, driveC: driveC)
        XCTAssertEqual(z?.path, "/Users/me/x")
        XCTAssertNil(WineReparsePoint.hostTarget(.init(tag: 0, target: "D:\\x", isRelative: false), stubParent: parent, driveC: driveC), "no such drive in a bottle")
    }

    // MARK: Following

    func testFollowReachesTheClientThroughTheStubAndWritesNothing() throws {
        let driveC = root.appending(path: "drive_c")
        let (dir, exe) = try makeEAInstall(under: driveC)
        let named = dir.appending(path: "EA Desktop/EADesktop.exe")
        XCTAssertEqual(WineReparsePoint.follow(named, driveC: driveC)?.path, exe.standardizedFileURL.path)
        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: dir.appending(path: "EA Desktop").path), "no Mac link is made")
        XCTAssertNotNil(WineReparsePoint.read(at: dir.appending(path: "EA Desktop?")), "the stub stays for Wine")
        XCTAssertNil(WineReparsePoint.follow(dir.appending(path: "EA Desktop/Missing.exe"), driveC: driveC))
        XCTAssertNil(WineReparsePoint.follow(root.appending(path: "outside/nothing"), driveC: driveC))
    }

    func testFollowGoesThroughAStubWithoutTheMarkerAndAnAbsoluteJunction() throws {
        let driveC = root.appending(path: "drive_c")
        let (dir, exe) = try makeEAInstall(under: driveC, stubName: "EA Desktop")
        XCTAssertEqual(WineReparsePoint.follow(dir.appending(path: "EA Desktop/EADesktop.exe"), driveC: driveC)?.path, exe.standardizedFileURL.path)
        let vendor = driveC.appending(path: "Program Files/Vendor")
        try FileManager.default.createDirectory(at: driveC.appending(path: "ProgramData/Vendor/1.0"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: driveC.appending(path: "ProgramData/Vendor/1.0/app.exe"))
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try makeStub(in: vendor, name: "Current?", data: Self.blob(tag: 0xA000_0003, substitute: "\\??\\C:\\ProgramData\\Vendor\\1.0", relative: false))
        XCTAssertEqual(WineReparsePoint.follow(vendor.appending(path: "Current/app.exe"), driveC: driveC)?.path,
                       driveC.appending(path: "ProgramData/Vendor/1.0/app.exe").standardizedFileURL.path)
        try makeStub(in: vendor, name: "Nowhere?", data: Self.blob(tag: 0xA000_000C, substitute: "no\\such", relative: true))
        XCTAssertNil(WineReparsePoint.follow(vendor.appending(path: "Nowhere/app.exe"), driveC: driveC))
    }

    func testWindowsPaths() {
        let driveC = root.appending(path: "drive_c")
        XCTAssertEqual(WineReparsePoint.windowsPath(for: driveC.appending(path: "Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe"), driveC: driveC),
                       "C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EADesktop.exe")
        XCTAssertEqual(WineReparsePoint.windowsPath(for: URL(fileURLWithPath: "/Volumes/Games/x.exe"), driveC: driveC), "Z:\\Volumes\\Games\\x.exe")
    }

    func testAPinBehindALinkIsFoundOnTheMacAndLaunchedByItsOwnPath() throws {
        let driveC = root.appending(path: "drive_c")
        let (_, exe) = try makeEAInstall(under: driveC)
        let pin = Pin(name: "EA app", path: "Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe")
        XCTAssertEqual(pin.executableURL(driveC: driveC).path, exe.standardizedFileURL.path, "checks, Finder and the PE read see the real file")
        XCTAssertEqual(pin.launchURL(driveC: driveC).path, driveC.appending(path: pin.path).path, "Wine gets the path through the link")
        let plain = Pin(name: "Notepad", path: "windows/notepad.exe")
        XCTAssertEqual(plain.executableURL(driveC: driveC), plain.launchURL(driveC: driveC), "an ordinary pin is unchanged")
    }

    // MARK: Undoing the old symlinks

    /// What an older Highball left: a relative Mac symlink at the link's name, beside the stub.
    func makeOldLink(in dir: URL, name: String = "EA Desktop", to destination: String = "13.783.0.6296/EA Desktop") throws {
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: name).path, withDestinationPath: destination)
    }

    func testDematerializeRemovesTheOldLinkAndNothingElse() throws {
        let driveC = root.appending(path: "drive_c")
        let (dir, exe) = try makeEAInstall(under: driveC)
        try makeOldLink(in: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appending(path: "Shortcut").path, withDestinationPath: "13.783.0.6296/EA Desktop")
        try makeStub(in: dir, name: "Other?", data: Self.blob(tag: 0xA000_000C, substitute: "13.783.0.6296", relative: true))
        try makeOldLink(in: dir, name: "Other", to: "13.783.0.6296/EA Desktop")
        let removed = WineReparsePoint.dematerialize(in: dir, driveC: driveC)
        XCTAssertEqual(removed.map(\.lastPathComponent), ["EA Desktop"])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "Shortcut").path), "a symlink with no stub beside it stays")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "Other").path), "a symlink pointing elsewhere than its stub stays")
        XCTAssertNotNil(WineReparsePoint.read(at: dir.appending(path: "EA Desktop?")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exe.path), "the files behind the link are untouched")
        XCTAssertEqual(WineReparsePoint.dematerialize(in: dir, driveC: driveC), [], "second pass: nothing left")
    }

    func testDematerializePutsAStubSetAsideBack() throws {
        let driveC = root.appending(path: "drive_c")
        let (dir, _) = try makeEAInstall(under: driveC, stubName: ".wine-reparse-EA Desktop")
        try makeOldLink(in: dir)
        XCTAssertEqual(WineReparsePoint.dematerialize(in: dir, driveC: driveC).map(\.lastPathComponent), ["EA Desktop"])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "EA Desktop").path))
        XCTAssertNotNil(WineReparsePoint.read(at: dir.appending(path: "EA Desktop")), "the stub is back at its own name")
        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: dir.appending(path: ".wine-reparse-EA Desktop").path))
    }

    func testDematerializeAlongAPathAndThroughATree() throws {
        let driveC = root.appending(path: "drive_c")
        let (dir, exe) = try makeEAInstall(under: driveC)
        try makeOldLink(in: dir)
        let named = dir.appending(path: "EA Desktop/EADesktop.exe")
        XCTAssertEqual(WineReparsePoint.dematerializeAlong(named, driveC: driveC).map(\.lastPathComponent), ["EA Desktop"])
        XCTAssertEqual(WineReparsePoint.follow(named, driveC: driveC)?.path, exe.standardizedFileURL.path, "still reachable through the stub")
        try makeOldLink(in: dir)
        try FileManager.default.createDirectory(at: driveC.appending(path: "windows/system32"), withIntermediateDirectories: true)
        let deep = driveC.appending(path: "a/b/c/d/e/f/g/h")
        try FileManager.default.createDirectory(at: deep.appending(path: "1.0/X"), withIntermediateDirectories: true)
        try makeStub(in: deep, name: "X?", data: Self.blob(tag: 0xA000_000C, substitute: "1.0\\X", relative: true))
        try makeOldLink(in: deep, name: "X", to: "1.0/X")
        XCTAssertEqual(WineReparsePoint.dematerializeTree(under: driveC, driveC: driveC).map(\.lastPathComponent), ["EA Desktop"],
                       "depth 3 is found, depth 8 is beyond the cap")
        XCTAssertEqual(WineReparsePoint.dematerializeTree(under: driveC, driveC: driveC, maxDepth: 10).map(\.lastPathComponent), ["X"])
    }

    func testABottleUnderPrivateKeepsItsDriveLetter() throws {
        // /var is a link to /private/var. Standardizing drops /private only from paths that exist,
        // so drive_c and a path through a link below it used to disagree, and a pin behind a link
        // was handed to Wine as Z:\\private\\... (exit 53, seen with a scratch home in /private/tmp).
        let real = URL(fileURLWithPath: "/private" + root.resolvingSymlinksInPath().path.replacingOccurrences(of: "/private", with: ""))
        let driveC = real.appending(path: "drive_c")
        let (dir, exe) = try makeEAInstall(under: driveC)
        let named = dir.appending(path: "EA Desktop/EADesktop.exe")
        XCTAssertEqual(WineReparsePoint.windowsPath(for: named, driveC: driveC), "C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EADesktop.exe")
        XCTAssertEqual(WineReparsePoint.follow(named, driveC: driveC)?.resolvingSymlinksInPath().path, exe.resolvingSymlinksInPath().path)
        try makeOldLink(in: dir)
        XCTAssertEqual(WineReparsePoint.dematerializeAlong(named, driveC: driveC).map(\.lastPathComponent), ["EA Desktop"])
    }
}
