import XCTest
@testable import HighballKit

/// Replacing an Epic build: the old one stays recoverable until the new one is in.
final class EpicBuildSwitchTests: XCTestCase {
    final class Log: @unchecked Sendable { var steps: [String] = [] }

    private func steps(_ log: Log, hasNew: Bool = true, replacing: Bool = true,
                       install: @escaping () async throws -> Void = {}) -> EpicBuildSwitch.Steps {
        EpicBuildSwitch.Steps(
            hasNewBuild: { log.steps.append("check"); return hasNew },
            dropOldRecord: replacing ? { log.steps.append("drop") } : nil,
            install: { log.steps.append("install"); try await install() },
            restoreOldRecord: { log.steps.append("restore") },
            deleteOldFiles: { log.steps.append("delete") })
    }

    func testTheOldFilesGoOnlyOnceTheNewBuildIsIn() async throws {
        let log = Log()
        try await EpicBuildSwitch.run(steps(log))
        XCTAssertEqual(log.steps, ["check", "drop", "install", "delete"])
    }

    func testNoNewBuildChangesNothing() async {
        let log = Log()
        do { try await EpicBuildSwitch.run(steps(log, hasNew: false)); XCTFail("no new build") } catch {
            XCTAssertEqual(error as? EpicBuildSwitch.Failure, .noNewBuild)
        }
        XCTAssertEqual(log.steps, ["check"])
    }

    /// A failed download, or legendary falling back to the old platform, puts the old record back.
    func testAFailedInstallPutsTheOldBuildBack() async {
        let log = Log()
        struct Boom: Error {}
        do { try await EpicBuildSwitch.run(steps(log, install: { throw Boom() })); XCTFail("failed") } catch { XCTAssertTrue(error is Boom) }
        XCTAssertEqual(log.steps, ["check", "drop", "install", "restore"])
    }

    /// Stop while Epic is asked: nothing is dropped.
    func testStopDuringTheCheckChangesNothing() async {
        let log = Log()
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await EpicBuildSwitch.run(EpicBuildSwitch.Steps(
                hasNewBuild: { log.steps.append("check"); started.continuation.yield(); try? await Task.sleep(for: .milliseconds(200)); return true },
                dropOldRecord: { log.steps.append("drop") }, install: { log.steps.append("install") },
                restoreOldRecord: { log.steps.append("restore") }, deleteOldFiles: { log.steps.append("delete") }))
        }
        for await _ in started.stream { break }
        task.cancel()
        do { try await task.value; XCTFail("stopped") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(log.steps, ["check"])
    }

    /// Stop during the download: the old record is put back.
    func testStopDuringTheDownloadPutsTheOldBuildBack() async {
        let log = Log()
        let task = Task { try await EpicBuildSwitch.run(steps(log, install: { try await Task.sleep(for: .seconds(5)) })) }
        while !log.steps.contains("install") { await Task.yield() }
        task.cancel()
        do { try await task.value; XCTFail("stopped") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(log.steps, ["check", "drop", "install", "restore"])
    }

    func testAPlainInstallHasNothingToDropOrDelete() async throws {
        let log = Log()
        try await EpicBuildSwitch.run(steps(log, replacing: false))
        XCTAssertEqual(log.steps, ["check", "install"])
    }

    func testOnlyAFolderInsideHighballsGameFoldersIsDeleted() {
        let roots = [URL(fileURLWithPath: "/E/drive_c/Games"), URL(fileURLWithPath: "/U/Applications/Highball Games")]
        XCTAssertTrue(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/E/drive_c/Games/Gungeon"), roots: roots))
        XCTAssertTrue(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/u/applications/highball games/Garlic"), roots: roots))
        XCTAssertFalse(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/E/drive_c/Games"), roots: roots))
        XCTAssertFalse(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/E/drive_c/Games/"), roots: roots))
        XCTAssertFalse(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/E/drive_c/Games2/X"), roots: roots))
        XCTAssertFalse(EpicBuildSwitch.isSafeToDelete(URL(fileURLWithPath: "/U/Applications"), roots: roots))
    }
}
