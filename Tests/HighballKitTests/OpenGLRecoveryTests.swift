import XCTest
@testable import HighballKit

final class OpenGLRecoveryTests: XCTestCase {
    private let textureError = #"OpenGL error 0x0501 in ..\renderer\CCTexture2D.cpp cocos2d::Texture2D::initWithMipmaps 669"#

    func testTextureFailureTakesPrecedenceOverSoftwareRendering() throws {
        let recovery = try XCTUnwrap(Recovery.openGL(output: "gl.renderer: llvmpipe (LLVM 23.1.2)\n" + textureError))
        XCTAssertEqual(recovery.headline, "The game could not initialize some textures.")
        XCTAssertEqual(recovery.action, .none)
        XCTAssertNil(recovery.actionTitle, "no unverified automatic driver change")
        XCTAssertTrue(recovery.meaning.contains("does not establish"), "a GL error alone cannot distinguish assets from driver bugs")
    }

    func testSoftwareRendererNeedsAnActualRendererLine() {
        for renderer in ["llvmpipe (LLVM 23.1.2, 128 bits)", "softpipe", "Software Rasterizer"] {
            XCTAssertEqual(Recovery.openGL(output: "gl.renderer: \(renderer)")?.headline,
                           "The game's OpenGL renderer is using the CPU.")
        }
        XCTAssertNotNil(Recovery.openGL(output: "OpenGL renderer string: llvmpipe"))
        XCTAssertNil(Recovery.openGL(output: "# GALLIUM_DRIVER=llvmpipe\nVK_EXT_texture_compression_astc_hdr"),
                     "requested settings and supported extensions do not prove which renderer ran")
        XCTAssertNil(Recovery.openGL(output: "gl.renderer: zink Vulkan 1.2 (Apple M3)"))
        XCTAssertNil(Recovery.openGL(output: "gl.renderer: M3 (WineMetalGL)"))
    }

    func testKnownContextRejectionButNoGuessFromANullPointer() {
        XCTAssertEqual(Recovery.openGL(output: "warn:wgl:macdrv_wglCreateContextAttribsARB OS X only supports forward-compatible 3.2+ contexts")?.headline,
                       "The game's OpenGL context was rejected.")
        XCTAssertNil(Recovery.openGL(output: "Ready for OpenGL 2.0\nwine: Unhandled page fault on read access to 00000000"))
        XCTAssertNil(Recovery.openGL(output: "OpenGL error 0x0501 in some unrelated operation"))
        XCTAssertNil(Recovery.openGL(output: ""))
    }

    func testRecoveryReadsABoundedLogAndHandlesMissingFiles() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hb-gl-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(Recovery.openGL(log: file))
        let noise = String(repeating: "chatter\n", count: 100_000)
        try (noise + textureError).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Recovery.openGL(log: file)?.headline, "The game could not initialize some textures.")
    }

    func testReportKeepsOpenGLIdentityAndTextureErrorsBeforeTheTail() {
        let identities = ["gl.version: 4.6.0 Compatibility Profile", "gl.vendor: Mesa", "gl.renderer: zink Vulkan Apple M3"]
        let text = (identities + [textureError, textureError] + (0..<100).map { "chatter \($0)" }).joined(separator: "\n")
        let digest = BugReport.digest(text)
        for identity in identities { XCTAssertTrue(digest.contains(identity)) }
        XCTAssertTrue(digest.contains(textureError + "  (x2)"))
        XCTAssertEqual(digest.components(separatedBy: "initWithMipmaps").count - 1, 1)
    }

    func testHeaderKeepsOnlyNamedOpenGLSwitches() {
        let env = ["GALLIUM_DRIVER": "zink", "LIBGL_ALWAYS_SOFTWARE": "0", "MESA_LOADER_DRIVER_OVERRIDE": "zink",
                   "MESA_SHADER_CACHE_DIR": "/private/path", "GALLIUM_TOKEN": "secret", "SECRET": "secret"]
        XCTAssertEqual(WineRunner.headerSwitchLines(env),
                       "# GALLIUM_DRIVER=zink\n# LIBGL_ALWAYS_SOFTWARE=0\n# MESA_LOADER_DRIVER_OVERRIDE=zink\n")
    }
}
