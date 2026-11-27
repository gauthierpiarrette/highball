import Foundation
import XCTest
@testable import HighballKit

final class CustomEngineManifestSourceTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManifestSourceProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }

    func testURLInputAcceptsHTTPAndHTTPSWithoutRequiringAFileExtension() {
        XCTAssertEqual(CustomEngineImport.manifestURL(from: "  https://engines.example/manifest?build=42\n")?.absoluteString,
                       "https://engines.example/manifest?build=42")
        XCTAssertNotNil(CustomEngineImport.manifestURL(from: "http://localhost:8000/engine.json"))
        for text in ["", "engine.json", "/tmp/engine.json", "file:///tmp/engine.json", "ftp://engines.example/engine.json", "https://"] {
            XCTAssertNil(CustomEngineImport.manifestURL(from: text), text)
        }
    }

    func testRemoteJSONLoadsWithoutAHighballRepositoryRestriction() async throws {
        let manifest = try await CustomEngineImport.load(from: URL(string: "https://engines.example/engine.json?build=42")!, session: session())
        XCTAssertEqual(manifest.id, "custom-url-engine-r1")
        XCTAssertEqual(manifest.components["wine"]?.url.absoluteString, "https://archives.example/wine.tar.gz")
    }

    func testLocalFileAndRemoteJSONUseTheSameLoaderAndValidation() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hb-manifest-source-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try ManifestSourceProtocol.manifestJSON.write(to: file)
        let manifest = try await CustomEngineImport.load(from: file)
        XCTAssertEqual(manifest.id, "custom-url-engine-r1")
        do {
            _ = try await CustomEngineImport.load(from: file, reservedIDs: [manifest.id])
            XCTFail("a reserved ID must fail for files too")
        } catch { XCTAssertTrue(String(describing: error).contains("unique ID")) }
    }

    func testRemoteReservedIDIsRejectedBeforeEngineInstallation() async throws {
        do {
            _ = try await CustomEngineImport.load(from: URL(string: "https://engines.example/engine.json")!,
                                                  reservedIDs: ["custom-url-engine-r1"], session: session())
            XCTFail("a reserved engine ID must fail")
        } catch { XCTAssertTrue(String(describing: error).contains("unique ID")) }
    }

    func testHTTPErrorIsRejectedEvenWhenTheBodyIsValidManifestJSON() async throws {
        do {
            _ = try await CustomEngineImport.load(from: URL(string: "https://engines.example/not-found.json")!, session: session())
            XCTFail("a non-success HTTP status must fail")
        } catch { XCTAssertTrue(String(describing: error).contains("successful response")) }
    }

    func testAWebPageInsteadOfJSONHasAnActionableError() async throws {
        do {
            _ = try await CustomEngineImport.load(from: URL(string: "https://engines.example/page")!, session: session())
            XCTFail("HTML must not be treated as an engine manifest")
        } catch { XCTAssertTrue(String(describing: error).contains("not a valid engine manifest")) }
    }

    func testCancellationIsPreservedForTheExistingStopFlow() async throws {
        do {
            _ = try await CustomEngineImport.load(from: URL(string: "https://engines.example/cancelled.json")!, session: session())
            XCTFail("a cancelled download must fail")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
    }

    func testUnsupportedSourceSchemeIsRejected() async throws {
        do {
            _ = try await CustomEngineImport.load(from: URL(string: "ftp://engines.example/engine.json")!, session: session())
            XCTFail("only file, HTTP and HTTPS sources are supported")
        } catch { XCTAssertTrue(String(describing: error).contains("HTTP or HTTPS")) }
    }
}

/// Exercise the real URLSession code without network access or a mutable global handler.
private final class ManifestSourceProtocol: URLProtocol, @unchecked Sendable {
    static let manifestJSON = Data("""
        {"id":"custom-url-engine-r1","displayName":"Custom URL engine","arch":"x86_64","minMacOS":"14.0",
         "components":{"wine":{"kind":"engine","url":"https://archives.example/wine.tar.gz",
         "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}
        """.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/cancelled.json" {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/not-found.json" ? 404 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: url.path == "/page" ? Data("<html>Not JSON</html>".utf8) : Self.manifestJSON)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
