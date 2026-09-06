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
        XCTAssertEqual(WineReparsePoint.linkName(forStub: "EA Desktop?"), "EA Desktop")
        XCTAssertEqual(WineReparsePoint.linkName(forStub: "plain"), "plain")
    }

    // MARK: Materialising

    func testStubBecomesARelativeHostSymlinkTheClientIsReachableThrough() throws {
        let driveC = root.appending(path: "drive_c")
        let (dir, _) = try makeEAInstall(under: driveC)
        let made = WineReparsePoint.materialize(in: dir, driveC: driveC)
        XCTAssertEqual(made.map(\.lastPathComponent), ["EA Desktop"])
        let link = dir.appending(path: "EA Desktop")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "13.783.0.6296/EA Desktop", "relative, so a moved bottle keeps working")
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.appending(path: "EADesktop.exe").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "EA Desktop?").path), "the stub is left for Wine")
        XCTAssertEqual(WineReparsePoint.materialize(in: dir, driveC: driveC), [], "second pass: nothing left to do")
    }

    func testStubWithoutTheMarkerIsMovedAsideForTheLink() throws {
        let driveC = root.appending(path: "drive_c")
        let (dir, _) = try makeEAInstall(under: driveC, stubName: "EA Desktop")
        XCTAssertEqual(WineReparsePoint.materialize(in: dir, driveC: driveC).map(\.lastPathComponent), ["EA Desktop"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "EA Desktop/EADesktop.exe").path))
        XCTAssertNotNil(WineReparsePoint.read(at: dir.appending(path: ".wine-reparse-EA Desktop")), "the stub survives, aside")
    }

    func testStubToNothingAndTakenNamesAreLeftAlone() throws {
        let driveC = root.appending(path: "drive_c")
        let dir = driveC.appending(path: "Program Files/Vendor")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeStub(in: dir, name: "Gone?", data: Self.blob(tag: 0xA000_000C, substitute: "9.9\\Gone", relative: true))
        try makeStub(in: dir, name: "Taken?", data: Self.blob(tag: 0xA000_000C, substitute: "9.9\\Gone", relative: true))
        try FileManager.default.createDirectory(at: dir.appending(path: "9.9/Gone"), withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "Taken"))
        try makeStub(in: dir, name: "Nowhere?", data: Self.blob(tag: 0xA000_000C, substitute: "no\\such", relative: true))
        let made = WineReparsePoint.materialize(in: dir, driveC: driveC)
        XCTAssertEqual(made.map(\.lastPathComponent), ["Gone"])
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "Taken")), Data(), "an existing file is never replaced")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "Nowhere").path))
    }

    func testAbsoluteJunctionGetsARelativeLink() throws {
        let driveC = root.appending(path: "drive_c")
        let dir = driveC.appending(path: "Program Files/Vendor")
        try FileManager.default.createDirectory(at: driveC.appending(path: "ProgramData/Vendor/1.0"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeStub(in: dir, name: "Current?", data: Self.blob(tag: 0xA000_0003, substitute: "\\??\\C:\\ProgramData\\Vendor\\1.0", relative: false))
        XCTAssertEqual(WineReparsePoint.materialize(in: dir, driveC: driveC).count, 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "Current").path), "../../ProgramData/Vendor/1.0")
    }

    func testResolveMaterialisesWhatStandsInThePathsWay() throws {
        let driveC = root.appending(path: "drive_c")
        let (dir, _) = try makeEAInstall(under: driveC)
        let pinned = dir.appending(path: "EA Desktop/EADesktop.exe")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinned.path))
        XCTAssertEqual(WineReparsePoint.resolve(pinned, driveC: driveC)?.path, pinned.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
        XCTAssertNil(WineReparsePoint.resolve(dir.appending(path: "EA Desktop/Missing.exe"), driveC: driveC))
        XCTAssertNil(WineReparsePoint.resolve(root.appending(path: "outside/nothing"), driveC: driveC))
    }

    func testTreeWalkFindsStubsAFewLevelsDownAndStopsAtTheDepthCap() throws {
        let driveC = root.appending(path: "drive_c")
        let (dir, _) = try makeEAInstall(under: driveC)
        try FileManager.default.createDirectory(at: driveC.appending(path: "windows/system32"), withIntermediateDirectories: true)
        let deep = driveC.appending(path: "a/b/c/d/e/f/g/h")
        try FileManager.default.createDirectory(at: deep.appending(path: "1.0/X"), withIntermediateDirectories: true)
        try makeStub(in: deep, name: "X?", data: Self.blob(tag: 0xA000_000C, substitute: "1.0\\X", relative: true))
        let made = WineReparsePoint.materializeTree(under: driveC, driveC: driveC)
        XCTAssertEqual(made.map(\.lastPathComponent), ["EA Desktop"], "depth 3 is found, depth 8 is beyond the cap")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "EA Desktop/EADesktop.exe").path))
        XCTAssertEqual(WineReparsePoint.materializeTree(under: driveC, driveC: driveC, maxDepth: 10).map(\.lastPathComponent), ["X"])
    }
}
