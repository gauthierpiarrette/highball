import XCTest
@testable import HighballKit

/// A minimal PE32+ with one section holding an export directory whose name is `exportName`.
/// Enough of a DLL for the parts of Highball that read PE headers.
enum SyntheticPE {
    static func make(exportName: String, extraNameRoom: Int = 0) -> Data {
        var d = Data(count: 0x600)
        func put16(_ v: UInt16, _ o: Int) { d[o] = UInt8(v & 0xff); d[o + 1] = UInt8(v >> 8) }
        func put32(_ v: UInt32, _ o: Int) { for i in 0..<4 { d[o + i] = UInt8((v >> (8 * i)) & 0xff) } }
        d[0] = 0x4D; d[1] = 0x5A                     // MZ
        put32(0x40, 0x3c)                            // e_lfanew
        d[0x40] = 0x50; d[0x41] = 0x45               // PE\0\0
        put16(0x8664, 0x44)                          // machine x64
        put16(1, 0x46)                               // one section
        put16(240, 0x54)                             // optional header size (PE32+)
        let opt = 0x58
        put16(0x20b, opt)                            // PE32+ magic
        put32(0x1000, opt + 112)                     // data directory 0: export table RVA
        put32(0x100, opt + 116)                      //   size
        let sec = opt + 240
        d.replaceSubrange(sec..<sec + 5, with: Array(".edata".utf8.prefix(5)))
        put32(0x200, sec + 8)                        // virtual size
        put32(0x1000, sec + 12)                      // virtual address
        put32(0x200, sec + 16)                       // raw size
        put32(0x400, sec + 20)                       // raw pointer
        let dir = 0x400
        put32(0x1000 + 40, dir + 12)                 // export directory Name RVA: right after the 40-byte directory
        let name = Array(exportName.utf8)
        d.replaceSubrange(dir + 40..<dir + 40 + name.count, with: name)
        // extraNameRoom: the zero padding after the name is not "room" unless the original name was longer
        _ = extraNameRoom
        return d
    }
}

final class PEExportNameTests: XCTestCase {
    func testReadsTheExportName() {
        XCTAssertEqual(PEExportName.read(SyntheticPE.make(exportName: "d3d12.dll")), "d3d12.dll")
        XCTAssertNil(PEExportName.read(Data("not a pe".utf8)))
        XCTAssertNil(PEExportName.read(Data()))
    }

    func testPatchesInPlaceWhenTheNewNameFits() throws {
        let original = SyntheticPE.make(exportName: "d3d12.dll")
        let patched = try PEExportName.patched(original, to: "apd12.dll")
        XCTAssertEqual(PEExportName.read(patched), "apd12.dll")
        XCTAssertEqual(patched.count, original.count, "nothing moves")
        let diff = zip(original, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        XCTAssertEqual(diff.count, 2, "only the bytes of the name that differ change (d3d12 -> apd12): \(diff)")
        let shorter = try PEExportName.patched(original, to: "ab.dll")
        XCTAssertEqual(PEExportName.read(shorter), "ab.dll", "a shorter name is zero padded")
    }

    func testRefusesALongerNameAndNonPEs() {
        XCTAssertThrowsError(try PEExportName.patched(SyntheticPE.make(exportName: "d3d12.dll"), to: "d3d12_d3dmetal.dll")) {
            XCTAssertEqual($0 as? PEExportName.Failure, .nameTooLong(max: 9))
        }
        XCTAssertThrowsError(try PEExportName.patched(Data("MZ nope".utf8), to: "x.dll")) {
            XCTAssertEqual($0 as? PEExportName.Failure, .notPE)
        }
    }

    /// The real thing, when this Mac has a licensed D3DMetal: the file Highball lays out must still
    /// be a PE Wine will take, so the patch is checked on Apple's own bytes.
    func testPatchesTheRealD3DMetalWhenPresent() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let engines = home.appending(path: "Library/Application Support/Highball/engines")
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: engines.path) else { throw XCTSkip("no engines here") }
        let real = ids.map { engines.appending(path: "\($0)/frameworks/renderer/d3dmetal/wine/x86_64-windows/d3d12.dll") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let real else { throw XCTSkip("no D3DMetal on this Mac") }
        let d = try Data(contentsOf: real)
        XCTAssertEqual(PEExportName.read(d), "d3d12.dll")
        XCTAssertEqual(PEExportName.read(try PEExportName.patched(d, to: "apd12.dll")), "apd12.dll")
    }
}
