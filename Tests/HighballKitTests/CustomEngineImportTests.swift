import XCTest
@testable import HighballKit

final class CustomEngineImportTests: XCTestCase {
    private func manifest() -> EngineManifest {
        EngineManifest(id: "custom-wine-test-r1", displayName: "Custom Wine", arch: "x86_64", minMacOS: "14.0",
                       components: ["wine": .init(kind: "engine", url: URL(string: "https://example.org/custom/wine.tar.gz")!,
                                                  sha256: String(repeating: "a", count: 64),
                                                  extract: .init(subpath: "engine", into: "engine"))])
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "hb-custom-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Tiny local archives exercise the real installer without downloading or running Wine.
    private func fixture(complete: Bool = true) throws -> (EngineStore, EngineManifest) {
        let root = try temporaryDirectory()
        let source = root.appending(path: "source")
        let files = complete ? InstalledEngine.requiredFiles : ["engine/bin/wine"]
        for file in files {
            let url = source.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        let archive = root.appending(path: "custom-wine.tar.gz")
        try Shell.run("/usr/bin/tar", ["-czf", archive.path, "-C", source.path, "engine"])
        let store = EngineStore(paths: HighballPaths(home: root.appending(path: "home")))
        var m = manifest()
        m.components["wine"]?.url = archive
        m.components["wine"]?.sha256 = try store.sha256(of: archive)
        return (store, m)
    }

    func testExistingJSONFormatAcceptsThirdPartyAndLocalSources() throws {
        let root = try temporaryDirectory()
        let file = root.appending(path: "engine.json")
        var m = manifest()
        m.channel = "preview"  // deliberate imports do not need a Highball channel opt-in
        try m.save(to: file)
        let loaded = try EngineManifest.load(from: file)
        XCTAssertNoThrow(try loaded.validateForCustomImport())
        XCTAssertEqual(loaded.components["wine"]?.url.host, "example.org")
        m.components["wine"]?.url = root.appending(path: "local archive.tar.gz")
        try m.save(to: file)
        XCTAssertTrue(try EngineManifest.load(from: file).components["wine"]!.url.isFileURL)
        try Data("{\"id\":\"incomplete-json\"}".utf8).write(to: file)
        XCTAssertThrowsError(try EngineManifest.load(from: file))
    }

    func testImportRequiresASafeUniqueIDAndCompleteSupportedEngine() {
        var m = manifest()
        for id in ["", ".hidden", "..", "../escape", "a/b", "/absolute", "a\\b", "a\n", "a b"] {
            m.id = id
            XCTAssertThrowsError(try m.validateForCustomImport(), id)
        }
        m = manifest()
        XCTAssertThrowsError(try m.validateForCustomImport(reservedIDs: [m.id]))
        m.components = [:]
        XCTAssertThrowsError(try m.validateForCustomImport())
        m = manifest(); m.arch = "unknown"
        XCTAssertThrowsError(try m.validateForCustomImport())
    }

    func testComponentPathsCannotEscapeTheEngine() {
        for path in ["../escape", "engine/../../escape", "/tmp/escape", "engine\\escape", ""] {
            var m = manifest()
            m.components["wine"]?.extract?.into = path
            XCTAssertThrowsError(try m.validateForCustomImport(), path)
        }
        var m = manifest()
        m.components["wine"]?.extract?.subpath = "../outside"
        XCTAssertThrowsError(try m.validateForCustomImport())
        m = manifest()
        m.components["../escape"] = m.components["wine"]
        XCTAssertThrowsError(try m.validateForCustomImport())
    }

    func testLocalImportPersistsAndIsOfferedWithoutBeingBundled() async throws {
        let (store, m) = try fixture()
        let installed = try await store.install(m, existingEnginePolicy: .reject)
        XCTAssertTrue(installed.isComplete)
        let reloaded = try EngineStore(paths: store.paths).installedEngines()
        XCTAssertEqual(reloaded.map(\.id), [m.id])
        XCTAssertEqual(EngineStore.offeredEngines(installed: reloaded, known: [], current: "another-engine").map(\.id),
                       [m.id, "another-engine"])
        XCTAssertEqual(EngineStore.removableEngines(installed: reloaded, referencedIDs: [], defaultID: "standard").map(\.id), [m.id])
        XCTAssertTrue(EngineStore.removableEngines(installed: reloaded, referencedIDs: [m.id], defaultID: "standard").isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.paths.engines.path), [m.id])
    }

    func testDuplicateIsRejectedBeforeReadingArchivesAndLeavesEngineUntouched() async throws {
        let (store, original) = try fixture()
        let installed = try await store.install(original, existingEnginePolicy: .reject)
        let manifestFile = installed.root.appending(path: "manifest.json")
        let saved = try Data(contentsOf: manifestFile)
        var duplicate = original
        duplicate.components["wine"]?.url = URL(fileURLWithPath: "/nonexistent/wine.tar.gz")
        do {
            _ = try await store.install(duplicate, existingEnginePolicy: .reject)
            XCTFail("duplicate should fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("unique ID"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: manifestFile), saved)
        XCTAssertTrue(installed.isComplete)
    }

    func testImportRejectsExistingFoldersAndDanglingSymlinks() async throws {
        let (store, m) = try fixture()
        try store.paths.ensure()
        let destination = store.paths.engine(m.id)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            _ = try await store.install(m, existingEnginePolicy: .reject)
            XCTFail("an existing directory is not replaced even without a manifest")
        } catch { XCTAssertTrue(String(describing: error).contains("unique ID")) }
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "/nonexistent/engine")
        do {
            _ = try await store.install(m, existingEnginePolicy: .reject)
            XCTFail("a dangling symlink is not replaced")
        } catch { XCTAssertTrue(String(describing: error).contains("unique ID")) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "/nonexistent/engine")
    }

    func testChecksumFailureCleansStagingAndCanBeRetried() async throws {
        let (store, good) = try fixture()
        var bad = good
        bad.components["wine"]?.sha256 = String(repeating: "0", count: 64)
        do {
            _ = try await store.install(bad, existingEnginePolicy: .reject)
            XCTFail("bad checksum should fail")
        } catch HighballError.checksumMismatch { /* expected */ }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.paths.engines.path), [])
        let retried = try await store.install(good, existingEnginePolicy: .reject)
        XCTAssertTrue(retried.isComplete)
    }

    func testIncompleteArchiveNeverBecomesInstalled() async throws {
        let (store, m) = try fixture(complete: false)
        do {
            _ = try await store.install(m, existingEnginePolicy: .reject)
            XCTFail("an incomplete Wine tree should fail")
        } catch { XCTAssertTrue(String(describing: error).contains("incomplete"), "\(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.paths.engines.path), [])
        XCTAssertTrue(try store.installedEngines().isEmpty)
    }

    func testCancelledImportDoesNotInstallAnythingAndCanBeRetried() async throws {
        let (store, m) = try fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.install(m, existingEnginePolicy: .reject)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled import should fail")
        } catch is CancellationError { /* expected */ }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.engine(m.id).path))
        let retried = try await store.install(m, existingEnginePolicy: .reject)
        XCTAssertTrue(retried.isComplete)
    }

    func testIncompatibleMacOSIsRejectedBeforeInstallation() async throws {
        let (store, original) = try fixture()
        var m = original
        m.minMacOS = "999.0"
        do {
            _ = try await store.install(m, existingEnginePolicy: .reject)
            XCTFail("an unsupported macOS version should fail")
        } catch { XCTAssertTrue(String(describing: error).contains("needs macOS")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.engine(m.id).path))
    }

    func testImportedAcceptanceDoesNotEnableGatedComponents() async throws {
        let (store, original) = try fixture()
        var m = original
        m.acceptedLicenses = ["custom-license"]
        m.components["gated"] = .init(kind: "renderer", url: URL(fileURLWithPath: "/nonexistent/gated.tar.gz"),
                                       sha256: "unused", optional: true, acceptance: "custom-license")
        let engine = try await store.install(m, existingEnginePolicy: .reject)
        XCTAssertEqual(engine.manifest.acceptedLicenses, [])
    }

    func testDefaultInstallPolicyStillAllowsRepairingAnExistingEngine() async throws {
        let (store, original) = try fixture()
        _ = try await store.install(original, existingEnginePolicy: .reject)
        var repair = original
        repair.displayName = "Repaired"
        let installed = try await store.install(repair)
        XCTAssertEqual(installed.displayName, "Repaired")
        XCTAssertTrue(installed.isComplete)
    }
}
