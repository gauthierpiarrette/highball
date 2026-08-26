import XCTest
@testable import HighballKit

/// Every recipe and db entry shipped from highball-db must decode with the current
/// Recipe/GameDBEntry types — this is the drift tripwire between the two repos.
/// Skips cleanly when the sibling checkout isn't present (e.g. bare CI).
final class RecipeDBTests: XCTestCase {

    private var dbRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "highball-db")
    }

    func testAllShippedRecipesDecode() throws {
        let recipes = dbRoot.appending(path: "recipes")
        guard FileManager.default.fileExists(atPath: recipes.path) else {
            throw XCTSkip("highball-db checkout not found next to the repo")
        }
        var checked = 0
        for sub in ["launchers", "games", "tweaks"] {
            let dir = recipes.appending(path: sub)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "json" {
                let r: Recipe
                do { r = try JSONDecoder.highball.decode(Recipe.self, from: Data(contentsOf: f)) }
                catch { XCTFail("\(f.lastPathComponent) failed to decode: \(error)"); continue }
                XCTAssertFalse(r.id.isEmpty, f.lastPathComponent)
                XCTAssertFalse(r.title.isEmpty, f.lastPathComponent)
                for step in r.steps {
                    if case let .installer(url, _, _, _) = step {
                        XCTAssertEqual(url.scheme, "https", "\(f.lastPathComponent): installer URLs must be https")
                    }
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 5, "expected to find shipped recipes; wrong path?")
    }

    func testAllShippedGameDBEntriesDecode() throws {
        let dir = dbRoot.appending(path: "db/games")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("highball-db checkout not found next to the repo")
        }
        var checked = 0
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        where f.pathExtension == "json" {
            do {
                let e = try JSONDecoder.highball.decode(GameDBEntry.self, from: Data(contentsOf: f))
                XCTAssertFalse(e.id.isEmpty, f.lastPathComponent)
                XCTAssertTrue(["verified-local", "reported-upstream", "community", "blocked-anticheat"].contains(e.status),
                              "\(f.lastPathComponent): unknown status '\(e.status)'")
            } catch {
                XCTFail("\(f.lastPathComponent) failed to decode: \(error)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    // The GOG recipe regression: the web installer trips its service-pack check under
    // Wine's win10 profile. The recipe must keep pointing at the offline installer.
    func testGogRecipeUsesOfflineInstaller() throws {
        let f = dbRoot.appending(path: "recipes/launchers/gog-galaxy.json")
        guard FileManager.default.fileExists(atPath: f.path) else {
            throw XCTSkip("highball-db checkout not found next to the repo")
        }
        let r = try JSONDecoder.highball.decode(Recipe.self, from: Data(contentsOf: f))
        let installers = r.steps.compactMap { step -> URL? in
            if case let .installer(url, _, _, _) = step { return url } else { return nil }
        }
        XCTAssertFalse(installers.contains { $0.absoluteString.contains("webinstallers") },
                       "web installer fails its Windows 7 SP1 check under wine win10 — use the offline setup exe")
    }
}
