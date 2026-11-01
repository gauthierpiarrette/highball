import Foundation

/// The purchases Steam knows on this Mac, from the client's appcache/packageinfo.vdf: one entry
/// per package an account signed in here owns (and free ones), with the apps and depots it brings.
/// Read for sizes only: which depots of a game a download would fetch.
public enum SteamPackageInfo {
    public struct Package: Sendable, Equatable {
        public let id: Int
        public let appIDs: Set<Int>
        public let depotIDs: Set<Int>
    }

    public static func read(steamRoot: URL) -> [Package] {
        guard let data = try? Data(contentsOf: steamRoot.appending(path: "appcache/packageinfo.vdf"), options: .mappedIfSafe) else { return [] }
        return parse(data)
    }

    /// v39/v40/v41: magic, universe, then per package its id, a SHA-1, a change number, a token
    /// (from v40), and a binary KeyValues object; an id of 0xFFFFFFFF ends the list.
    /// What parsed before a damaged entry, rather than nothing: one bad record must not hide every
    /// purchase. An unknown version reads as none.
    static func parse(_ data: Data) -> [Package] {
        var r = SteamAppInfo.Reader(bytes: [UInt8](data))
        guard let magic = try? r.u32(), magic & 0xFFFF_FF00 == 0x0656_5500, magic & 0xFF >= 0x27, (try? r.u32()) != nil else { return [] }
        let hasToken = magic & 0xFF >= 0x28
        var packages: [Package] = []
        while let id = try? r.u32(), id != 0xFFFF_FFFF {
            r.offset += 20 + 4 + (hasToken ? 8 : 0)
            guard let root = try? r.object(nil) else { break }
            let package = root.values.first?.object ?? root
            func ids(_ key: String) -> Set<Int> { Set((package[key]?.object ?? [:]).values.compactMap { $0.string.flatMap(Int.init) }) }
            packages.append(Package(id: Int(id), appIDs: ids("appids"), depotIDs: ids("depotids")))
        }
        return packages
    }
}

/// How much a Steam game's download is before it is installed, from Steam's own data on the Mac:
/// the depots for the platform and language that come with what the accounts here own. A game
/// can list several editions' depots (Little Nightmares III lists two of about 15 GB; the
/// purchases here bring one), so the packages decide, not a sum of everything listed.
public enum SteamDownloadSize {
    public static func estimate(appID: Int, app: SteamAppInfo.App, packages: [Package], mac: Bool,
                                language: String = "english") -> DownloadEstimate? {
        guard packages.contains(where: { $0.appIDs.contains(appID) }) else { return nil }
        // Every purchase counts, not only the game's: a DLC bought on its own is a package of its
        // own, and its depots (dlcAppID) come along with the game. Depots are the game's own
        // list, so another game's in these sets never count.
        let ownedDepots = packages.reduce(into: Set<Int>()) { $0.formUnion($1.depotIDs) }
        let ownedApps = packages.reduce(into: Set<Int>()) { $0.formUnion($1.appIDs) }
        let picked = app.depots.filter { depot in
            guard ownedDepots.contains(depot.id) || (depot.dlcAppID != 0 && ownedApps.contains(depot.dlcAppID)) else { return false }
            guard !depot.restricted, depot.size > 0 else { return false }
            let os = depot.oslist.lowercased()
            guard os.isEmpty || os.contains(mac ? "macos" : "windows") else { return false }
            return depot.language.isEmpty || depot.language.lowercased() == language
        }
        guard !picked.isEmpty else { return nil }
        return DownloadEstimate(download: picked.reduce(0) { $0 + $1.download }, disk: picked.reduce(0) { $0 + $1.size })
    }

    public typealias Package = SteamPackageInfo.Package
}
