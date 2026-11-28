import Foundation

/// Presentation data shared by creation and switching. Installed engines keep their own
/// manifest metadata; a bundled manifest describes a download only when it is not installed.
public struct EngineChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let arch: String?
    public let requiresRosetta: Bool
    public let installed: Bool
    public let custom: Bool
    public let channel: String?
    public let minMacOS: String?
    public let downloadBytes: Int
    public let supported: Bool
    public let requiresNewEnvironment: Bool
    public let missing: Bool
    public var selectable: Bool { arch != nil && supported }
}

extension EngineStore {
    /// `known` is already channel-filtered by the caller. Unlike the old creation picker,
    /// both architectures and every installed custom engine are represented. Current and
    /// draft choices survive revision filtering, including a missing current engine.
    public static func engineChoices(installed: [InstalledEngine], known: [EngineManifest], bundledIDs: Set<String>? = nil,
                                     currentID: String? = nil, selectedID: String? = nil,
                                     allRevisions: Bool = false, macOS: String = EngineManifest.currentMacOS) -> [EngineChoice] {
        let manifests = installed.map(\.manifest) + known
        // Include installed builds outside this app's shipped catalog, such as CLI-installed engines.
        let catalogIDs = bundledIDs ?? Set(known.map(\.id))
        let customIDs = Set(installed.map(\.id)).subtracting(catalogIDs)
        let currentArch = manifests.first { $0.id == currentID }?.arch
        var rows = offeredEngines(installed: installed, known: known, macOS: macOS, allRevisions: allRevisions)
        for id in [currentID, selectedID].compactMap({ $0 }) where !rows.contains(where: { $0.id == id }) {
            // Pin an older visible manifest, but never add a hidden download by ID alone.
            if let m = manifests.first(where: { $0.id == id }) {
                rows.append(OfferedEngine(id: id, installed: false, displayName: m.displayName))
            } else {
                rows.append(OfferedEngine(id: id, installed: false, missing: true))
            }
        }
        let firstID = selectedID ?? currentID
        var seen = Set<String>()
        rows = rows.filter { seen.insert($0.id).inserted }
        rows.sort {
            if ($0.id == firstID) != ($1.id == firstID) { return $0.id == firstID }
            if ($0.id == currentID) != ($1.id == currentID) { return $0.id == currentID }
            if $0.installed != $1.installed { return $0.installed }
            return $0.id.compare($1.id, options: .numeric) == .orderedDescending
        }
        return rows.map { row in
            let m = manifests.first { $0.id == row.id }
            return EngineChoice(id: row.id, displayName: m?.displayName ?? row.id,
                                arch: m?.arch, requiresRosetta: m?.requiresRosetta ?? false,
                                installed: row.installed, custom: customIDs.contains(row.id),
                                channel: m?.channel, minMacOS: m?.minMacOS, downloadBytes: m?.downloadBytes ?? 0,
                                supported: m?.runs(onMacOS: macOS) ?? false,
                                requiresNewEnvironment: m.map { !sameArch(current: currentArch, target: $0.arch) } ?? false,
                                missing: row.missing || (row.id == currentID && !row.installed))
        }
    }
}
