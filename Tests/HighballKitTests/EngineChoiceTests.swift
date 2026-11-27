import XCTest
@testable import HighballKit

final class EngineChoiceTests: XCTestCase {
    private func manifest(_ id: String, arch: String = "x86_64", floor: String = "14.0") -> EngineManifest {
        EngineManifest(id: id, displayName: "Build \(id)", arch: arch, minMacOS: floor, components: [:])
    }

    private func installed(_ manifests: EngineManifest...) -> [InstalledEngine] {
        manifests.map { InstalledEngine(manifest: $0, root: URL(fileURLWithPath: "/unused/\($0.id)")) }
    }

    func testCreationIncludesSameArchitectureCustomAndEveryInstalledRevision() {
        let standard = manifest("x64-test-r10"), old = manifest("x64-test-r2"), custom = manifest("my-custom-build")
        let rows = EngineStore.engineChoices(installed: installed(standard, old, custom), known: [standard], bundledIDs: [standard.id, old.id],
                                            selectedID: standard.id, macOS: "27.0")
        XCTAssertEqual(Set(rows.map(\.id)), [standard.id, old.id, custom.id])
        XCTAssertEqual(rows.first?.id, standard.id)
        XCTAssertTrue(rows.first { $0.id == custom.id }!.custom)
        XCTAssertFalse(rows.first { $0.id == old.id }!.custom)
        XCTAssertTrue(rows.allSatisfy { $0.selectable && !$0.requiresNewEnvironment })
    }

    func testOtherArchitecturesAreSelectableForCreationAndSeparateForSwitching() {
        let intel = manifest("x64-test-r1"), native = manifest("arm64-test-r1", arch: "arm64")
        let have = installed(intel, native)
        let create = EngineStore.engineChoices(installed: have, known: [], selectedID: native.id, macOS: "27.0")
        XCTAssertEqual(create.first?.id, native.id)
        XCTAssertTrue(create.allSatisfy { $0.selectable && !$0.requiresNewEnvironment })
        let edit = EngineStore.engineChoices(installed: have, known: [], currentID: intel.id, macOS: "27.0")
        XCTAssertTrue(edit.first { $0.id == native.id }!.requiresNewEnvironment)
        let reverse = EngineStore.engineChoices(installed: have, known: [], currentID: native.id, macOS: "27.0")
        XCTAssertTrue(reverse.first { $0.id == intel.id }!.requiresNewEnvironment)
    }

    func testRevisionFilterKeepsDraftAndMacOSFlavoursButExcludesUnsupportedDownloads() {
        let old = manifest("x64-test-r2"), latest = manifest("x64-test-r10"), metal = manifest("x64-test-r11", floor: "27.0")
        let future = manifest("x64-test-r12", floor: "28.0")
        let known = [old, latest, metal, future]
        let rows = EngineStore.engineChoices(installed: [], known: known, selectedID: old.id, macOS: "27.0")
        XCTAssertEqual(rows.map(\.id), [old.id, metal.id, latest.id])
        let unpinned = EngineStore.engineChoices(installed: [], known: known, macOS: "27.0")
        XCTAssertEqual(Set(unpinned.map(\.id)), [metal.id, latest.id])
        let expanded = EngineStore.engineChoices(installed: [], known: known, allRevisions: true, macOS: "27.0")
        XCTAssertEqual(Set(expanded.map(\.id)), [old.id, metal.id, latest.id])
    }

    func testUnsupportedInstalledEngineAndMissingAssignmentStayVisible() {
        let current = manifest("x64-current-r1", floor: "28.0"), replacement = manifest("x64-other-r1")
        let unsupported = EngineStore.engineChoices(installed: installed(current), known: [replacement],
                                                   currentID: current.id, macOS: "27.0")
        XCTAssertEqual(unsupported.first?.id, current.id)
        XCTAssertFalse(unsupported.first!.selectable)
        XCTAssertEqual(unsupported.first?.minMacOS, "28.0")
        let missing = EngineStore.engineChoices(installed: installed(replacement), known: [current],
                                               currentID: current.id, macOS: "27.0")
        XCTAssertTrue(missing.first!.missing)
        XCTAssertFalse(missing.first!.selectable)
        let unknown = EngineStore.engineChoices(installed: installed(replacement), known: [], currentID: "gone", macOS: "27.0")
        XCTAssertEqual(unknown.first?.id, "gone")
        XCTAssertTrue(unknown.first!.missing)
        XCTAssertFalse(unknown.first!.selectable)
        XCTAssertFalse(unknown.last!.requiresNewEnvironment, "Preserve the existing unknown-architecture backend policy")
    }

    func testMissingKnownAssignmentRetainsItsArchitectureAndCanBeReinstalled() {
        let current = manifest("arm64-test-r1", arch: "arm64"), other = manifest("x64-test-r1")
        let rows = EngineStore.engineChoices(installed: installed(other), known: [current], currentID: current.id, macOS: "27.0")
        XCTAssertTrue(rows.first!.missing)
        XCTAssertTrue(rows.first!.selectable, "The known manifest can be downloaded again")
        XCTAssertTrue(rows.last!.requiresNewEnvironment)
    }

    func testChannelFilteringCannotBeBypassedByPinningHiddenID() {
        let standard = manifest("x64-test-r1")
        var hidden = manifest("arm64-preview-r1", arch: "arm64"); hidden.channel = EngineChannels.preview
        let bundled = [standard, hidden]
        let visible = bundled.filter { EngineChannels.visible($0, beta: false, preview: false, optedIn: []) }
        let rows = EngineStore.engineChoices(installed: installed(standard), known: visible,
                                            selectedID: hidden.id, macOS: "27.0")
        let pin = rows.first { $0.id == hidden.id }!
        XCTAssertTrue(pin.missing)
        XCTAssertFalse(pin.selectable)
        XCTAssertNil(pin.arch)
    }

    func testInstalledMetadataWinsAndChoicesHaveUniqueStableIDs() {
        var bundled = manifest("x64-test-r1")
        bundled.requires = ["rosetta2"]
        bundled.components["wine"] = EngineManifest.Component(kind: "wine", url: URL(string: "https://example.com/wine.tar.xz")!, sha256: "a", size: 123)
        var local = bundled; local.displayName = "Installed display name"
        let rows = EngineStore.engineChoices(installed: installed(local), known: [bundled, bundled], macOS: "27.0")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].displayName, local.displayName)
        XCTAssertEqual(rows[0].downloadBytes, 123)
        XCTAssertTrue(rows[0].requiresRosetta)
    }
}
