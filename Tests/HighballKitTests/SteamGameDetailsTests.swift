import XCTest
@testable import HighballKit

final class SteamGameDetailsTests: XCTestCase {
    private let sample = Data(#"""
    {"42":{"success":true,"data":{"steam_appid":42,
      "platforms":{"mac":true},"short_description":"Explore &amp; survive &#8212; together.",
      "about_the_game":"<h2>A world</h2><p>Play &lt;your way&gt;.</p><script>hidden()</script><ul><li>Explore</li><li>Build</li></ul>",
      "header_image":"https://shared.akamai.steamstatic.com/header.jpg",
      "screenshots":[
        {"path_thumbnail":"https://shared.akamai.steamstatic.com/thumb.jpg","path_full":"https://shared.akamai.steamstatic.com/full.jpg"},
        {"path_thumbnail":"https://shared.akamai.steamstatic.com/thumb.jpg","path_full":"https://shared.akamai.steamstatic.com/full.jpg"},
        {"path_thumbnail":"https://example.com/thumb.jpg","path_full":"file:///tmp/image.jpg"}],
      "developers":["Studio"],"publishers":["Publisher"],"genres":[{"description":"Action"}],
      "release_date":{"date":"6 Oct, 2026","coming_soon":false}}}}
    """#.utf8)

    private func cacheDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "highball-steam-details-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testParsesStoreCopyWithoutHTMLAndRejectsUnsafeOrDuplicateImages() throws {
        let details = try XCTUnwrap(SteamGameDetails.parse(sample, appID: 42))
        XCTAssertEqual(details.summary, "Explore & survive — together.")
        XCTAssertEqual(details.description, "A world\n\nPlay <your way>.\n\n• Explore\n• Build")
        XCTAssertEqual(details.screenshots.count, 1)
        XCTAssertEqual(details.developers, ["Studio"])
        XCTAssertEqual(details.genres, ["Action"])
        XCTAssertEqual(details.releaseDate, "6 Oct, 2026")
        XCTAssertEqual(details.storeURL.absoluteString, "https://store.steampowered.com/app/42/")
    }

    func testDelistedMalformedAndMismatchedRepliesAreUnavailable() {
        XCTAssertNil(SteamGameDetails.parse(Data(#"{"42":{"success":false}}"#.utf8), appID: 42))
        XCTAssertNil(SteamGameDetails.parse(Data("not JSON".utf8), appID: 42))
        XCTAssertNil(SteamGameDetails.parse(sample, appID: 43))
        let mismatch = Data(#"{"42":{"success":true,"data":{"steam_appid":43}}}"#.utf8)
        XCTAssertNil(SteamGameDetails.parse(mismatch, appID: 42))
    }

    func testEntityDecodingDoesNotInterpretEscapedMarkupOrLoadImages() {
        XCTAssertEqual(SteamGameDetails.plainText("<p>&lt;script&gt; &#x1F3AE; &amp;quot;</p><img src='https://example.com/a'>"), "<script> 🎮 &quot;")
        XCTAssertEqual(SteamGameDetails.plainText("a&nbsp; b<br> c"), "a b\n\nc")
        XCTAssertEqual(SteamGameDetails.plainText("<p>A</p>\r\n<br><br>\r\n<p>B</p>"), "A\n\nB")
    }

    func testSparseStoreReplyStillHasAUsablePage() throws {
        let empty = Data(#"{"42":{"success":true,"data":{"steam_appid":42}}}"#.utf8)
        let details = try XCTUnwrap(SteamGameDetails.parse(empty, appID: 42))
        XCTAssertEqual(details.summary, "")
        XCTAssertEqual(details.screenshots, [])
        XCTAssertNil(details.header)
        XCTAssertNil(details.releaseDate)
    }

    func testCacheSurvivesRelaunchAndLanguagesHaveSeparateCopies() async throws {
        let directory = try cacheDirectory(), now = Date(timeIntervalSince1970: 1000)
        let probe = FetchProbe(data: sample)
        let store = SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) })
        let first = await store.details(appID: 42, now: now)
        let second = await store.details(appID: 42, now: now.addingTimeInterval(60))
        XCTAssertEqual(first, second)
        let relaunched = SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) })
        let persisted = await relaunched.details(appID: 42, now: now.addingTimeInterval(120))
        XCTAssertEqual(first, persisted)
        let englishCalls = await probe.calls
        XCTAssertEqual(englishCalls.count, 1)
        _ = await relaunched.details(appID: 42, language: .french, now: now)
        let allCalls = await probe.calls
        XCTAssertEqual(allCalls.count, 2)
        XCTAssertTrue(allCalls.last?.query?.contains("l=french") == true)
    }

    func testExpiredCopyRemainsAvailableWhenSteamRateLimitsAndRetryIsBackedOff() async throws {
        let directory = try cacheDirectory(), now = Date(timeIntervalSince1970: 1000)
        let probe = FetchProbe(data: sample)
        let store = SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) })
        let original = await store.details(appID: 42, now: now)
        await probe.setStatus(429)
        let later = now.addingTimeInterval(SteamGameDetailsStore.maxAge + 1)
        let stale = await store.details(appID: 42, now: later)
        let backedOff = await store.details(appID: 42, now: later.addingTimeInterval(60))
        XCTAssertEqual(stale, original)
        XCTAssertEqual(backedOff, original)
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 2)
        await probe.setStatus(200)
        let recovered = await store.details(appID: 42, now: later.addingTimeInterval(SteamAppDetailsClient.failureAge + 1))
        XCTAssertEqual(recovered, original)
        let afterRetry = await probe.calls
        XCTAssertEqual(afterRetry.count, 3)
    }

    func testOverlappingPagesShareOneRequest() async throws {
        let probe = FetchProbe(data: sample, delay: true)
        let store = SteamGameDetailsStore(directory: try cacheDirectory(), fetch: { try await probe.fetch($0) })
        async let first = store.details(appID: 42)
        async let second = store.details(appID: 42)
        let (a, b) = await (first, second)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testUnavailablePageFailureSurvivesRelaunchForADay() async throws {
        let directory = try cacheDirectory(), now = Date(timeIntervalSince1970: 1000)
        let probe = FetchProbe(data: Data(#"{"42":{"success":false}}"#.utf8))
        let store = SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) })
        let missing = await store.details(appID: 42, now: now)
        XCTAssertNil(missing)
        let relaunched = SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) })
        _ = await relaunched.details(appID: 42, now: now.addingTimeInterval(23 * 3600))
        let beforeExpiry = await probe.calls
        XCTAssertEqual(beforeExpiry.count, 1)
        _ = await relaunched.details(appID: 42, now: now.addingTimeInterval(24 * 3600 + 1))
        let afterExpiry = await probe.calls
        XCTAssertEqual(afterExpiry.count, 2)
    }

    func testMacFlagsAndGameDetailsShareOneResponseInEitherOrder() async throws {
        for flagsFirst in [false, true] {
            let directory = try cacheDirectory(), now = Date(timeIntervalSince1970: 1000)
            let probe = FetchProbe(data: sample)
            let client = SteamAppDetailsClient(directory: directory, fetch: { try await probe.fetch($0) })
            let details = SteamGameDetailsStore(client: client)
            let flags = MacFlagStore(file: directory.appending(path: "mac-flags.json"))
            if flagsFirst { _ = await flags.refresh([42], now: now, client: client) }
            let game = await details.details(appID: 42, now: now)
            let mac = await flags.refresh([42], now: now, client: client)
            XCTAssertNotNil(game)
            XCTAssertEqual(mac[42], true)
            let calls = await probe.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testRateLimitStopsBothConsumersAndDoesNotInventNegativeMacFlags() async throws {
        let directory = try cacheDirectory(), now = Date(timeIntervalSince1970: 1000)
        let probe = FetchProbe(data: sample)
        await probe.setStatus(429)
        let client = SteamAppDetailsClient(directory: directory, fetch: { try await probe.fetch($0) })
        let flags = MacFlagStore(file: directory.appending(path: "mac-flags.json"))
        let mac = await flags.refresh([42, 43, 44], now: now, client: client)
        XCTAssertTrue(mac.isEmpty)
        let game = await SteamGameDetailsStore(client: client).details(appID: 45, now: now)
        XCTAssertNil(game)
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 1)
        let relaunched = SteamAppDetailsClient(directory: directory, fetch: { try await probe.fetch($0) })
        _ = await relaunched.appDetails(appID: 42, now: now.addingTimeInterval(60))
        let afterRelaunch = await probe.calls
        XCTAssertEqual(afterRelaunch.count, 2)
    }

    func testConnectionErrorsRetryOnNextOpenAndAfterRelaunch() async throws {
        for error in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost] {
            for relaunch in [false, true] {
                let directory = try cacheDirectory(), now = Date(timeIntervalSince1970: 1000)
                let probe = FetchProbe(data: sample)
                await probe.setError(error)
                let store = SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) })
                let offline = await store.details(appID: 42, now: now)
                XCTAssertNil(offline)
                await probe.setError(nil)
                let next = relaunch ? SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) }) : store
                let online = await next.details(appID: 42, now: now.addingTimeInterval(1))
                XCTAssertNotNil(online)
                let calls = await probe.calls
                XCTAssertEqual(calls.count, 2)
            }
        }
    }

    func testStaleDetailsSurviveATimeoutWithoutDelayingNextRetry() async throws {
        let directory = try cacheDirectory(), now = Date(timeIntervalSince1970: 1000)
        let probe = FetchProbe(data: sample)
        let store = SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) })
        let original = await store.details(appID: 42, now: now)
        await probe.setError(.timedOut)
        let expired = now.addingTimeInterval(SteamGameDetailsStore.maxAge + 1)
        let offline = await store.details(appID: 42, now: expired)
        XCTAssertEqual(offline, original)
        await probe.setError(nil)
        let online = await store.details(appID: 42, now: expired.addingTimeInterval(1))
        XCTAssertEqual(online, original)
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 3)
    }

    func testMalformedAndServerErrorRepliesAreNotCachedForADay() async throws {
        for (data, status) in [(Data("not JSON".utf8), 200), (sample, 500),
                               (Data(#"{"43":{"success":false}}"#.utf8), 200)] {
            let probe = FetchProbe(data: data)
            await probe.setStatus(status)
            let store = SteamGameDetailsStore(directory: try cacheDirectory(), fetch: { try await probe.fetch($0) })
            _ = await store.details(appID: 42)
            _ = await store.details(appID: 42)
            let calls = await probe.calls
            XCTAssertEqual(calls.count, 2)
        }
    }

    func testLegacyFailureCacheDoesNotBlockRetry() async throws {
        let directory = try cacheDirectory(), now = Date(timeIntervalSince1970: 1000)
        // Version 1 cannot distinguish an offline lookup from Steam's explicit success:false.
        let legacy = try JSONSerialization.data(withJSONObject: ["version": 1,
            "checked": now.timeIntervalSinceReferenceDate, "failed": now.timeIntervalSinceReferenceDate])
        try legacy.write(to: directory.appending(path: "42-english.json"))
        let probe = FetchProbe(data: sample)
        let store = SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) })
        let recovered = await store.details(appID: 42, now: now.addingTimeInterval(1))
        XCTAssertNotNil(recovered)
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testCorruptCacheRefetchesAndInvalidAppDoesNotRequest() async throws {
        let directory = try cacheDirectory()
        try Data("bad cache".utf8).write(to: directory.appending(path: "42-english.json"))
        let probe = FetchProbe(data: sample)
        let store = SteamGameDetailsStore(directory: directory, fetch: { try await probe.fetch($0) })
        let invalid = await store.details(appID: -1)
        XCTAssertNil(invalid)
        let recovered = await store.details(appID: 42)
        XCTAssertNotNil(recovered)
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 1)
    }
}

private actor FetchProbe {
    let data: Data
    let delay: Bool
    var status = 200
    var error: URLError.Code?
    var calls: [URL] = []
    init(data: Data, delay: Bool = false) { self.data = data; self.delay = delay }
    func setStatus(_ status: Int) { self.status = status }
    func setError(_ error: URLError.Code?) { self.error = error }
    func fetch(_ url: URL) async throws -> (Data, Int) {
        calls.append(url)
        if let error { throw URLError(error) }
        if delay { try? await Task.sleep(for: .milliseconds(50)) }
        return (data, status)
    }
}
