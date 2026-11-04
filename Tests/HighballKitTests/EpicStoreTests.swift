import XCTest
@testable import HighballKit

final class EpicStoreTests: XCTestCase {
    /// highball#409: an install legendary refused reached the player as "epic install exited with 1".
    func testLegendaryInstallFailuresBecomeSentences() {
        XCTAssertEqual(EpicStore.installFailure("[cli] CRITICAL: Not enough available disk space! 51200.00 MiB < 122880.00 MiB"),
                       "This Mac doesn't have enough free space for the game. It needs 120 GB and 50 GB are free. Free some space, then press Install again.")
        XCTAssertNil(EpicStore.installFailure("[cli] CRITICAL: Installation cannot proceed, exiting."), "the summary line adds nothing")
        XCTAssertEqual(EpicStore.installFailure("[cli] ERROR: Game is not owned by this account"),
                       "Epic's installer stopped with this message. Game is not owned by this account")
        XCTAssertNil(EpicStore.installFailure("[cli] INFO: Download size: 95232.19 MiB (Compression savings: 2.1%)"))
    }

    /// Legendary has no terminal under Highball: the selective-download prompt (optional
    /// language packs) raised EOFError and killed the install (#110). `-y` alone does not skip it.
    /// legendary's lines as a GTA V Enhanced install printed them (highball#287): the size once,
    /// then the amount downloaded, which the activity strip turns into a bar and bytes.
    func testLegendarySizeAndProgressLines() {
        XCTAssertEqual(EpicStore.downloadSize(inLegendaryLine: "[cli] INFO: Download size: 95232.19 MiB (Compression savings: 2.1%)"),
                       Int64(95232.19 * 1_048_576))
        XCTAssertEqual(EpicStore.downloaded(inLegendaryLine: "[DLManager] INFO:  - Downloaded: 9075.51 MiB, Written: 9415.55 MiB"),
                       Int64(9075.51 * 1_048_576))
        for other in ["[DLManager] INFO: = Progress: 10.07% (10035/99671), Running for 00:06:22, ETA: 00:56:57",
                      "[DLManager] INFO:  - Cache usage: 463.00 MiB, active tasks: 32",
                      "[DLManager] INFO:  + Download\t- 27.94 MiB/s (raw) / 27.94 MiB/s (decompressed)",
                      "[cli] INFO: Install size: 97000.00 MiB",
                      "[DLManager] INFO:  - Downloaded: n/a"] {
            XCTAssertNil(EpicStore.downloadSize(inLegendaryLine: other), other)
            XCTAssertNil(EpicStore.downloaded(inLegendaryLine: other), other)
        }
    }

    func testInstallAnswersEveryPromptOnTheCommandLine() {
        let args = EpicStore.installArguments(appName: "Phoenix", basePath: "/c/Games")
        XCTAssertTrue(args.contains("-y"))
        XCTAssertTrue(args.contains("--skip-sdl"))
        XCTAssertEqual(Array(args.prefix(2)), ["install", "Phoenix"])
        XCTAssertEqual(args[args.firstIndex(of: "--base-path")! + 1], "/c/Games")
    }

    /// highball#566: one Epic game moves to another environment through `legendary move`, which
    /// prints its refusals and exits 0, so the folder's new place is what says it worked.
    func testMoveGoesThroughLegendaryAndChecksTheFolder() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hb-epicmove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = HighballPaths(home: home)
        let store = EpicStore(paths: paths)
        let fm = FileManager.default
        try fm.createDirectory(at: store.binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A stand-in with legendary 0.21.0's behaviour: rename the folder into the new base, or
        // print the refusal it printed for a full folder of that name there, with status 0.
        try """
        #!/bin/sh
        [ "$1" = move ] || exit 2
        src="$HB_TEST_SRC"; dst="$3/$(basename "$src")"
        if [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then echo "[cli] ERROR: Moving failed with unknown error OSError(66, 'Directory not empty')."; exit 0; fi
        rmdir "$dst" 2>/dev/null
        mv "$src" "$dst"; echo "[cli] INFO: Finished."
        """.write(to: store.binary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.binary.path)
        let a = Bottle(url: home.appending(path: "bottles/A"), settings: BottleSettings(name: "A", engineID: "e"))
        let b = Bottle(url: home.appending(path: "bottles/B"), settings: BottleSettings(name: "B", engineID: "e"))
        let game = a.driveC.appending(path: "Games/GetHighEXE")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        setenv("HB_TEST_SRC", game.path, 1)
        defer { unsetenv("HB_TEST_SRC") }

        XCTAssertEqual(EpicStore.moveArguments(appName: "app", basePath: "/x/drive_c/Games"), ["move", "app", "/x/drive_c/Games"])
        XCTAssertNil(try store.move("app", from: game.path, into: b))
        XCTAssertTrue(fm.fileExists(atPath: b.driveC.appending(path: "Games/GetHighEXE").path))
        XCTAssertTrue(EpicStore.isInstalled(path: b.driveC.appending(path: "Games/GetHighEXE").path, inDriveC: b.driveC))

        // Back to A while A holds a full folder of that name: refused, and said so.
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: game.appending(path: "left.txt"))
        setenv("HB_TEST_SRC", b.driveC.appending(path: "Games/GetHighEXE").path, 1)
        XCTAssertEqual(try store.move("app", from: b.driveC.appending(path: "Games/GetHighEXE").path, into: a),
                       "That environment already has a folder of that name in drive_c/Games. Remove or rename it, then try again.")
        XCTAssertEqual(EpicStore.moveFailure("Moving failed with unknown error PermissionError()."), "Moving failed with unknown error PermissionError().")
    }
}
