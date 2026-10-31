import Foundation

/// How much room a game takes: before an install, what the store says the download and the
/// installed game will be; once installed, its folder and its saves as they are on disk.
public struct DownloadEstimate: Sendable, Equatable {
    public let download: Int64?
    public let disk: Int64?

    public init(download: Int64?, disk: Int64?) { self.download = download; self.disk = disk }
}

public enum DiskUsage {
    /// The space a file or folder takes on disk, as Finder counts it (allocated, not logical,
    /// size). Links are not followed, so a folder linked into an environment (the Mac's
    /// Documents) is never counted as the game's. nil when nothing is there.
    public static func bytes(at url: URL) -> Int64? {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        func size(_ file: URL) -> Int64 {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard isFolder.boolValue else { return size(url) }
        var total: Int64 = 0
        let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let file = walker?.nextObject() as? URL { total += size(file) }
        return total
    }

    /// The total over several places, nil when none of them exists.
    public static func bytes(at urls: [URL]) -> Int64? {
        let sizes = urls.compactMap { bytes(at: $0) }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

extension EpicStore {
    /// What legendary says a download of the game's build for `platform` ("Windows" or "Mac")
    /// takes, from its manifest: the bytes fetched and the installed size.
    public func downloadEstimate(_ appName: String, platform: String = "Windows") throws -> DownloadEstimate {
        let out = try capture(["info", appName, "--json", "--platform", platform])
        return Self.parseEstimate(Data(out.utf8)) ?? DownloadEstimate(download: nil, disk: nil)
    }

    static func parseEstimate(_ data: Data) -> DownloadEstimate? {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let obj = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any],
              let manifest = obj["manifest"] as? [String: Any] else { return nil }
        return DownloadEstimate(download: (manifest["download_size"] as? NSNumber)?.int64Value,
                                disk: (manifest["disk_size"] as? NSNumber)?.int64Value)
    }
}

extension SteamLibrary {
    /// Steam's own copy of a game's cloud saves, one folder per account that has played it
    /// (userdata/<account>/<appid>). Games keeping saves elsewhere (Documents, AppData) are not
    /// in it, so this is a floor, labelled as Steam Cloud's.
    public static func cloudSaveFolders(steamRoot: URL, appID: Int) -> [URL] {
        let userdata = steamRoot.appending(path: "userdata", directoryHint: .isDirectory)
        let accounts = (try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil)) ?? []
        return accounts.map { $0.appending(path: String(appID), directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
