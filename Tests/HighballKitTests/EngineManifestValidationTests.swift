import XCTest
@testable import HighballKit

/// The schema checker consumes the same examples so changes cannot quietly split
/// the authoring contract from what app and CLI installations actually accept.
final class EngineManifestValidationTests: XCTestCase {
    private func cases() throws -> [(name: String, valid: Bool, data: Data)] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/engine-manifest-validation.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let base = try XCTUnwrap(fixture["base"] as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        return try cases.map { item in
            var document = base
            for change in item["changes"] as! [[String: Any]] {
                func apply(_ path: ArraySlice<String>, to object: inout [String: Any]) {
                    let key = path.first!
                    if path.count == 1 {
                        if change["remove"] as? Bool == true { object.removeValue(forKey: key) }
                        else { object[key] = change["value"] }
                    } else {
                        var child = object[key] as! [String: Any]
                        apply(path.dropFirst(), to: &child)
                        object[key] = child
                    }
                }
                apply(ArraySlice(change["path"] as! [String]), to: &document)
            }
            return (item["name"] as! String, item["valid"] as! Bool, try JSONSerialization.data(withJSONObject: document))
        }
    }

    func testSharedContractExamples() throws {
        for example in try cases() {
            do {
                let manifest = try JSONDecoder().decode(EngineManifest.self, from: example.data)
                try manifest.validate()
                XCTAssertTrue(example.valid, example.name)
            } catch {
                XCTAssertFalse(example.valid, "\(example.name): \(error)")
            }
        }
    }

    func testBothInstallPoliciesRejectInvalidManifestsBeforeCreatingAHome() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-contract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EngineStore(paths: HighballPaths(home: root))
        for example in try cases() where !example.valid {
            // Decode failures cannot reach EngineStore; exercise every semantic rejection
            // through both the app import policy and the CLI/default repair policy.
            guard let manifest = try? JSONDecoder().decode(EngineManifest.self, from: example.data) else { continue }
            for policy: EngineStore.ExistingEnginePolicy in [.replace, .reject] {
                do {
                    _ = try await store.install(manifest, existingEnginePolicy: policy)
                    XCTFail("\(example.name) must fail before installation")
                } catch {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "\(example.name): \(error)")
                }
            }
        }
    }

    func testReadingAnOlderManifestDoesNotRequireInstallability() throws {
        let data = try XCTUnwrap(try cases().first { $0.name == "no Wine component" }?.data)
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-old-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try data.write(to: root)
        let manifest = try EngineManifest.load(from: root)
        XCTAssertTrue(manifest.components.isEmpty)
        XCTAssertThrowsError(try manifest.validate())
    }
}
