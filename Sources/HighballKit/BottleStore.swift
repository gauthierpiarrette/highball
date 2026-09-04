import Foundation

public struct BottleStore: Sendable {
    public let paths: HighballPaths
    public init(paths: HighballPaths = HighballPaths()) { self.paths = paths }

    public func list() throws -> [Bottle] {
        guard FileManager.default.fileExists(atPath: paths.bottles.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: paths.bottles, includingPropertiesForKeys: nil)
            .compactMap { url -> Bottle? in
                guard var b = try? Bottle.load(url) else { return nil }
                // The folder is the bottle's identity (get/delete resolve by folder). A copied
                // folder keeps the old internal name, which crashed the app and confused lookups
                // (issue #13) — reconcile so "play copy" is simply a bottle called "play copy".
                if b.settings.name != url.lastPathComponent || b.settings.needsSave {
                    b.settings.name = url.lastPathComponent
                    // Reconcile in memory always, but persist only into a real directory: saving
                    // through a symlinked entry rewrites a bottle.json outside bottles/ as a side
                    // effect of merely listing. Skipping such entries entirely would be worse —
                    // a bottle deliberately linked to another disk would vanish from the list.
                    var st = stat()
                    if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { try? b.save(); b.settings.needsSave = false }
                }
                return b
            }
            .sorted { $0.name < $1.name }
    }

    public func get(_ name: String) throws -> Bottle {
        // Every subcommand resolves through here, so the name guard belongs here too rather than
        // only on the destructive calls.
        try Bottle.load(try Self.bottleURL(name, in: paths))
    }

    /// Returns a human-readable problem with a bottle name, or nil if it is usable.
    /// The bottle directory becomes part of the Wine prefix's Windows-side path (Z:\…\bottles\<name>\),
    /// so characters Windows forbids in paths break prefix initialization outright:
    /// wineboot exits 53 with "could not load kernel32.dll, status c0000135" (issue #12).
    public static func nameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "The bottle name is empty." }
        if trimmed.contains(where: { #"\/:*?"<>|"#.contains($0) }) {
            return #"A bottle name can't contain \ / : * ? " < > | — Windows paths forbid them, which would break the bottle."#
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "The bottle name contains control characters."
        }
        if trimmed.hasPrefix(".") { return "A bottle name can't start with a dot." }
        if trimmed.hasSuffix(".") { return "A bottle name can't end with a dot." }
        if trimmed.count > 64 { return "The bottle name is too long (64 characters max)." }
        return nil
    }

    /// Creates the directory + bottle.json, then runs `wineboot -u` to populate the prefix.
    public func create(name rawName: String, engine: InstalledEngine, renderer: Renderer = .dxmt, windowsVersion: WindowsVersion = .win10) async throws -> Bottle {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let problem = Self.nameProblem(name) { throw HighballError.invalid(problem) }
        try paths.ensure()
        let url = try Self.bottleURL(name, in: paths)
        // lstat, not fileExists: fileExists follows symlinks, so a dangling one sailed through
        // this guard and createDirectory then failed with a raw Foundation error on a name the
        // user could not see in the list.
        var existing = stat()
        guard lstat(url.path, &existing) != 0 else { throw HighballError.invalid("bottle '\(name)' already exists") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var settings = BottleSettings(name: name, engineID: engine.id)
        settings.renderer = renderer
        settings.windowsVersion = windowsVersion
        let bottle = Bottle(url: url, settings: settings)
        try bottle.save()
        let runner = WineRunner(paths: paths, engine: engine, bottle: bottle)
        let result = try await runner.wineboot()
        guard result.exitStatus == 0 else {
            throw HighballError.processFailed(command: "wineboot -u", status: result.exitStatus, output: "see \(result.log.path)")
        }
        do {
            try await Self.ensureWoW64(runner: runner, bottle: bottle, log: result.log)
        } catch {
            // Don't strand a half-built bottle: it can never run a 32-bit installer, and leaving
            // it behind means retrying with the same name hits "bottle already exists". This has
            // to go through discard() for the same reason delete() does — a plain removeItem
            // here fails the same way (#38) and, wrapped in try?, strands the bottle silently.
            try? runner.kill()
            _ = try? discard(url, name: name)
            throw error
        }
        if windowsVersion != .win10 { try await runner.setWindowsVersion(windowsVersion) }
        try? await runner.setGpuIdentity()
        try? await runner.setServiceTimeout()
        try? await runner.setKeyboardMapping(commandIsControl: bottle.settings.commandIsControl)
        return bottle
    }

    /// True when the prefix's 32-bit half is missing, the state issue #37 users found only when an
    /// installer died with "could not load kernel32.dll". Checked before every launch.
    public static func needsPreflightRepair(_ bottle: Bottle) -> Bool {
        !FileManager.default.fileExists(atPath: woW64Kernel32(in: bottle).path)
    }

    /// Quiet self-heal before a launch: when the 32-bit half is missing, re-run the first boot
    /// (with the mscoree set-aside and the 32-bit seeding refreshPrefix carries) instead of
    /// letting the launch fail and sending the user to find "Repair bottle".
    public static func preflight(runner: WineRunner, bottle: Bottle, log: ((String) -> Void)? = nil) async throws {
        guard needsPreflightRepair(bottle) else { return }
        log?("bottle '\(bottle.name)': 32-bit half missing, repairing before launch")
        try await refreshPrefix(runner: runner, bottle: bottle)
    }

    /// Re-runs the Windows first boot on an existing bottle and the per-bottle setup that boot
    /// resets: the 32-bit half check (#37), the GPU identity, the service timeout and the
    /// keyboard mapping. Repair, an engine switch and the CLI's repair all go through here;
    /// bottle creation keeps its own sequence because it also discards a half-built bottle.
    public static func refreshPrefix(runner: WineRunner, bottle: Bottle) async throws {
        let r = try await runner.wineboot()
        guard r.exitStatus == 0 else {
            throw HighballError.processFailed(command: "wineboot -u", status: r.exitStatus, output: "see \(r.log.path)")
        }
        try await ensureWoW64(runner: runner, bottle: bottle, log: r.log)
        try? await runner.setGpuIdentity()
        try? await runner.setServiceTimeout()
        try? await runner.setKeyboardMapping(commandIsControl: bottle.settings.commandIsControl)
    }

    /// The 32-bit half of a prefix, and whether it is actually there.
    ///
    /// Wine populates `syswow64` by launching a 32-bit rundll32 for the inf's Wow64Install
    /// section; if that launch fails, wineboot's loop skips the wait and **still exits 0**
    /// (verified in wineboot.c). So an exit-code check cannot tell a working bottle from one
    /// with no 32-bit support — which is exactly issue #37: bottles create "fine", then every
    /// installer dies with `could not load kernel32.dll, status c0000135`, because Wine will
    /// not fall back to the engine's i386-windows dlls outside prefix bootstrap. Most Windows
    /// installers are 32-bit, so such a bottle can install nothing at all.
    public static func woW64Kernel32(in bottle: Bottle) -> URL {
        bottle.driveC.appending(path: "windows/syswow64/kernel32.dll")
    }

    /// Verifies the 32-bit half exists and repairs it when it doesn't, so a prefix that missed
    /// Wine's WoW64 step still ends up usable instead of failing every install.
    ///
    /// The repair is to place the engine's 32-bit builtins into `syswow64` ourselves. That is
    /// not a workaround so much as the same outcome by a shorter route: a healthy prefix's
    /// syswow64 files are byte-identical copies of `lib/wine/i386-windows` (verified), Wine
    /// just normally puts them there via a 32-bit rundll32 that is exactly what fails here.
    /// Verified end to end: a bottle with an emptied syswow64 goes from
    /// "could not load kernel32.dll" to running 32-bit programs and installing Steam.
    public static func ensureWoW64(runner: WineRunner, bottle: Bottle, log: URL) async throws {
        if FileManager.default.fileExists(atPath: woW64Kernel32(in: bottle).path) { return }
        _ = try? await runner.wineboot(force: true)
        if FileManager.default.fileExists(atPath: woW64Kernel32(in: bottle).path) { return }
        try? seedWoW64(from: runner.engine, into: bottle)
        guard FileManager.default.fileExists(atPath: woW64Kernel32(in: bottle).path) else {
            // Wine only falls back to the engine's 32-bit builtins while a prefix is
            // bootstrapping, so a prefix that missed this step cannot be repaired in place
            // (verified: re-running wineboot, forced or not, leaves syswow64 empty). A fresh
            // bottle is the fix, which is why creation fails here rather than later.
            throw HighballError.invalid("""
                Windows 32-bit support couldn't be set up in this bottle, so most installers \
                can't run in it (they fail with "could not load kernel32.dll"), and repairing \
                it from the engine didn't work either. Please report this with the log \
                attached and we'll dig in: \(log.path)
                """)
        }
    }

    /// Copies the engine's 32-bit PE builtins into the prefix's `syswow64`, which is what Wine's
    /// WoW64 setup step would have done. Existing files are left alone, so this only fills gaps.
    static func seedWoW64(from engine: InstalledEngine, into bottle: Bottle) throws {
        let source = engine.engineDir.appending(path: "lib/wine/i386-windows", directoryHint: .isDirectory)
        let dest = bottle.driveC.appending(path: "windows/syswow64", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw HighballError.missing("the engine's 32-bit Windows files (\(source.path))")
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            let target = dest.appending(path: name)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try? FileManager.default.copyItem(at: source.appending(path: name), to: target)
        }
    }

    /// Copies a bottle under a new name (default "<name> copy", uniquified). Callers should stop
    /// the bottle's wineserver first so the registry files on disk are flushed and consistent.
    public func duplicate(_ name: String, as newName: String? = nil) throws -> Bottle {
        let source = try get(name)
        var target = newName ?? "\(name) copy"
        if newName == nil {
            var i = 2
            while FileManager.default.fileExists(atPath: paths.bottle(target).path) { target = "\(name) copy \(i)"; i += 1 }
        }
        if let problem = Self.nameProblem(target) { throw HighballError.invalid(problem) }
        let dest = paths.bottle(target)
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw HighballError.invalid("bottle '\(target)' already exists") }
        try FileManager.default.copyItem(at: source.url, to: dest)
        var copy = try Bottle.load(dest)
        copy.settings.name = target
        try copy.save()
        return copy
    }

    /// Deletes a bottle by moving it out of `bottles/` first, then purging it.
    ///
    /// The move is one `rename(2)`: it either happens or it doesn't, so a bottle can never be
    /// left half-deleted. A recursive remove can, and did (#38) — it walks the prefix in readdir
    /// order and abandons the rest of a directory at the first entry macOS refuses to unlink.
    /// `drive_c` sorts last in a bottle, so a blocker almost anywhere destroys `bottle.json`
    /// first, and that made the bottle invisible to `list()`, refused by `delete()`'s old
    /// bottle.json guard and blocked by `create()`'s name check, with its files still on disk.
    ///
    /// Returns whatever the purge could not remove. The bottle is gone from `bottles/` and its
    /// name is free either way; leftovers wait in `.trash` for `sweepTrash()` to retry.
    @discardableResult
    public func delete(_ name: String) throws -> [PurgeFailure] {
        // Resolve by folder, not by bottle.json. The folder is the bottle's identity — the same
        // rule list() reconciles names to — and a bottle whose settings file is unreadable is
        // precisely the one that most needs deleting.
        let url = try Self.bottleURL(name, in: paths)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw HighballError.missing("bottle '\(name)'") }
        return try discard(url, name: name)
    }

    /// Moves a bottle directory into `.trash` and purges it there. Shared by `delete` and
    /// `create`'s rollback so both are atomic in the only way that matters to the user: the
    /// moment the call returns, the name is reusable.
    @discardableResult
    func discard(_ url: URL, name: String) throws -> [PurgeFailure] {
        Purge.tree(at: try moveToTrash(url, name: name))
    }

    /// The atomic half, split out so the rename can be tested on its own: once the purge has run
    /// there is nothing left to compare, and a copy-then-delete implementation would look
    /// identical from the outside.
    func moveToTrash(_ url: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: paths.trash, withIntermediateDirectories: true)
        // rename(2) needs write on the two parent directories and nothing else, so it succeeds
        // over trees removeItem cannot touch (0555 and 0000 directories, uchg flags, deny-delete
        // ACLs). A poisoned root node is the one case it can't, so repair that node first.
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
            // Only a real directory is repaired, and only through lchflags/fchmodat, which do not
            // follow links: chmod(2) here would have rewritten the mode of whatever a symlinked
            // bottle entry pointed at, outside bottles/ entirely.
            if st.st_flags != 0 { _ = lchflags(url.path, 0) }
            if (st.st_mode & 0o700) != 0o700 {
                let parent = open(paths.bottles.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                if parent >= 0 {
                    _ = fchmodat(parent, url.lastPathComponent, st.st_mode | 0o700, AT_SYMLINK_NOFOLLOW)
                    close(parent)
                }
            }
        }
        let target = paths.trash.appending(path: "\(Self.trashName(name))-\(UUID().uuidString)",
                                           directoryHint: .isDirectory)
        // rename(2) and deliberately not FileManager.moveItem: across filesystems moveItem
        // copies and then deletes, and the delete half fails exactly the way #38 does, leaving a
        // whole copy at the destination and a gutted source. rename returns EXDEV and touches
        // neither side, which is the failure we want if `home` is ever split across volumes.
        guard rename(url.path, target.path) == 0 else {
            let code = errno
            // Something else already removed it — two deletes of the same bottle race here, and
            // telling the loser "nothing was removed and the bottle still works" would be a lie.
            if code == ENOENT { throw HighballError.missing("bottle '\(name)'") }
            let why = String(cString: strerror(code))
            throw HighballError.failed("""
                Couldn't delete '\(name)'. Highball couldn't move it out of the bottles folder \
                (\(why)). Nothing was removed and the bottle still works.
                """)
        }
        return target
    }

    /// Resolves a bottle name to its directory, refusing anything that is not a single component
    /// inside `bottles/`.
    ///
    /// This guard is load-bearing for a destructive call. delete() used to be protected by
    /// accident: its old bottle.json check meant a traversing name found no settings file and was
    /// rejected. Removing that check for #38 removed the protection with it, and
    /// `highball bottle delete ../../Something` then resolved outside the bottles folder and
    /// purged it — found in review, reproduced against the built CLI.
    static func bottleURL(_ name: String, in paths: HighballPaths) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.unicodeScalars.contains("\0") else {
            throw HighballError.invalid("'\(name)' isn't a bottle name")
        }
        let url = paths.bottle(name)
        // Belt and braces: whatever the name did, the result must sit directly in bottles/.
        guard url.deletingLastPathComponent().standardizedFileURL.path
                == paths.bottles.standardizedFileURL.path else {
            throw HighballError.invalid("'\(name)' isn't a bottle name")
        }
        return url
    }

    /// Bottle names are user-supplied, so keep them from steering the trash path anywhere.
    static func trashName(_ name: String) -> String {
        let safe = name.map { $0 == "/" || $0 == ":" || $0 == "." ? "_" : $0 }
        return safe.isEmpty ? "bottle" : String(safe.prefix(64))
    }

    /// Directories under `bottles/` that `list()` cannot show, because their settings file is
    /// missing or unreadable. `list()` and `damaged()` together cover every folder, so a bottle
    /// can never be invisible again — being invisible is what stranded the reporter of #38.
    public func damaged() throws -> [DamagedBottle] {
        guard FileManager.default.fileExists(atPath: paths.bottles.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: paths.bottles, includingPropertiesForKeys: nil)
            .compactMap { url -> DamagedBottle? in
                let name = url.lastPathComponent
                if name.hasPrefix(".") { return nil }
                // Deliberately lstat and no S_IFDIR requirement: anything occupying a name in
                // bottles/ blocks create() and must therefore be reachable. Requiring a directory
                // left a stray file or a dangling symlink invisible to both list() and damaged()
                // while still taking the name — the #38 stranding shape in miniature.
                var st = stat()
                guard lstat(url.path, &st) == 0 else { return nil }
                if (try? Bottle.load(url)) != nil { return nil }
                let reason: String
                if (st.st_mode & S_IFMT) != S_IFDIR {
                    reason = "something that isn't a bottle is using this name"
                } else if FileManager.default.fileExists(atPath: url.appending(path: "drive_c/windows").path) {
                    // A real prefix that lost its settings, rather than the wreckage of a delete.
                    reason = "its bottle.json is missing or unreadable"
                } else {
                    reason = "a delete stopped part way and left these files behind"
                }
                return DamagedBottle(name: name, url: url, reason: reason)
            }
            .sorted { $0.name < $1.name }
    }

    /// Retries anything a previous purge left in `.trash`. Cheap when it is empty, which is the
    /// normal case, so it is safe to call at launch and before each delete: a leftover whose
    /// cause was transient clears itself with no user action.
    @discardableResult
    public func sweepTrash() -> [(entry: URL, failures: [PurgeFailure])] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: paths.trash, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url in
            let failures = Purge.tree(at: url)
            return failures.isEmpty ? nil : (url, failures)
        }
    }

    public func update(_ bottle: Bottle) throws { try bottle.save() }
}

/// A directory under `bottles/` that isn't a loadable bottle. Surfaced so the user can act on
/// it: without a UI row there is no way to reach a bottle whose settings file is gone.
public struct DamagedBottle: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let url: URL
    public let reason: String

    public init(name: String, url: URL, reason: String) {
        self.name = name
        self.url = url
        self.reason = reason
    }
}
