import XCTest
@testable import HighballKit

final class PlayReportTests: XCTestCase {
    func testFormFieldsArePrefilledById() throws {
        let url = PlayReport.url(title: "Counter-Strike 2", appid: 730, renderer: "dxmt", chip: "Apple M1 Pro",
                                 macos: "26.6.2", engine: "x64-sikarugir10.0_6-r1", minutes: 23)
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "github.com")
        XCTAssertEqual(comps.path, "/gauthierpiarrette/highball-db/issues/new")
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["template"], "report.yml")
        XCTAssertEqual(q["title"], "Counter-Strike 2")
        XCTAssertEqual(q["steam_appid"], "730")
        XCTAssertEqual(q["renderer"], "dxmt")
        XCTAssertEqual(q["chip"], "Apple M1 Pro")
        XCTAssertEqual(q["macos"], "26.6.2")
        XCTAssertEqual(q["engine"], "x64-sikarugir10.0_6-r1")
        XCTAssertEqual(q["notes"], "Played for 23 min through Highball.")
        XCTAssertNil(q["rating"], "the rating is the player's to give")
    }

    func testUnknownAppIDAndRendererAreLeftOut() throws {
        let url = PlayReport.url(title: "X", appid: nil, renderer: nil, chip: "c", macos: "m", engine: "e", minutes: 1)
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        XCTAssertFalse(names.contains("steam_appid"))
        XCTAssertFalse(names.contains("renderer"))
    }

    func testSessionRecordWithoutRendererStillDecodes() throws {
        let old = Data(#"{"title":"T","bottle":"B","appid":1,"started":0,"ended":120,"reason":"ended"}"#.utf8)
        let r = try JSONDecoder().decode(SessionRecord.self, from: old)
        XCTAssertNil(r.renderer)
        XCTAssertEqual(r.seconds, 120)
    }
}
