import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import HighballKit

/// highball#175: dropping an image on a game should set its cover, including an image dragged out
/// of a browser, which arrives as bytes with no file behind it. Whatever the source, what gets
/// stored is the same normalised form a chosen file produces.
final class CoverDropTests: XCTestCase {
    private var home: URL!
    private var store: CoverStore!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "covers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = CoverStore(paths: HighballPaths(home: home))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testImageBytesBecomeACoverJustLikeAFile() throws {
        let data = try pngData(width: 800, height: 400)
        try store.setCover(for: "steam:620", imageData: data)
        let url = try XCTUnwrap(store.coverURL(for: "steam:620"), "no cover was stored")
        let stored = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(Double(stored.width) / Double(stored.height), CoverStore.aspect, accuracy: 0.01,
                       "a dropped image is cropped to the same 2:3 as a chosen one")
        XCTAssertLessThanOrEqual(stored.height, CoverStore.maxHeight)
    }

    func testAFileAndTheSameBytesGiveTheSameCover() throws {
        let data = try pngData(width: 600, height: 900)
        let file = home.appending(path: "art.png")
        try data.write(to: file)
        try store.setCover(for: "pin:a", from: file)
        let fromFile = try Data(contentsOf: try XCTUnwrap(store.coverURL(for: "pin:a")))
        try store.setCover(for: "pin:b", imageData: data)
        let fromBytes = try Data(contentsOf: try XCTUnwrap(store.coverURL(for: "pin:b")))
        XCTAssertEqual(fromFile, fromBytes, "the drop must not produce a different image from the file chooser")
    }

    func testRubbishBytesAreRefusedWithSomethingToDoAboutIt() {
        XCTAssertThrowsError(try store.setCover(for: "steam:1", imageData: Data("not an image".utf8))) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("PNG"), text)
            XCTAssertNil(self.store.coverURL(for: "steam:1"), "nothing is stored when the bytes are not an image")
        }
    }

    func testANewCoverReplacesTheOldOneRatherThanPilingUp() throws {
        try store.setCover(for: "steam:620", imageData: try pngData(width: 400, height: 600))
        try store.setCover(for: "steam:620", imageData: try pngData(width: 1200, height: 800))
        let dir = home.appending(path: "covers")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(files.count, 1, "one cover per game: \(files)")
    }
}
