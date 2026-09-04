import XCTest
@testable import HighballKit

final class ActivityTextTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func sample(_ mb: Double, _ seconds: TimeInterval) -> ActivityText.Sample {
        .init(bytes: Int64(mb * 1_048_576), at: t0.addingTimeInterval(seconds))
    }

    func testRateNeedsASecondOfSamples() {
        XCTAssertNil(ActivityText.rate([]))
        XCTAssertNil(ActivityText.rate([sample(1, 0)]))
        XCTAssertNil(ActivityText.rate([sample(1, 0), sample(2, 0.5)]))
    }

    func testRateIsMeasuredOverTheWindow() {
        let r = ActivityText.rate([sample(0, 0), sample(2, 1), sample(4, 2), sample(6, 3)])
        XCTAssertEqual(r.map { $0 / 1_048_576 } ?? 0, 2, accuracy: 0.01)
        // Samples older than the window do not drag the rate down.
        let stalled = ActivityText.rate([sample(0, 0), sample(0, 60), sample(10, 62), sample(20, 64)])
        XCTAssertEqual(stalled.map { $0 / 1_048_576 } ?? 0, 5, accuracy: 0.01)
    }

    func testANewFileRestartsTheRate() {
        // The second component starts from zero: its rate must not go negative or mix files.
        let r = ActivityText.rate([sample(100, 0), sample(110, 1), sample(1, 2), sample(3, 4)])
        XCTAssertEqual(r.map { $0 / 1_048_576 } ?? 0, 1, accuracy: 0.01)
    }

    func testTransferText() {
        XCTAssertEqual(ActivityText.transfer(received: 164 << 20, total: 270 << 20, rate: 2.4 * 1_048_576), "164 of 270 MB · 2.4 MB/s")
        XCTAssertEqual(ActivityText.transfer(received: 164 << 20, total: nil, rate: nil), "164 MB")
        XCTAssertEqual(ActivityText.transfer(received: 5 << 20, total: 0, rate: 640 * 1024), "5 MB · 640 KB/s")
    }

    func testFractionAndSteps() {
        XCTAssertEqual(ActivityText.fraction(received: 135 << 20, total: 270 << 20) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(ActivityText.fraction(received: 1, total: nil))
        XCTAssertEqual(ActivityText.fraction(received: 300, total: 200), 1)
        XCTAssertEqual(ActivityText.steps(in: "Step 2 of 3 — Battle.net-Setup")?.done, 2)
        XCTAssertEqual(ActivityText.steps(in: "Step 2 of 3")?.total, 3)
        XCTAssertNil(ActivityText.steps(in: "Downloading wine"))
    }

    func testMinutes() {
        XCTAssertNil(ActivityText.minutes(since: t0, now: t0.addingTimeInterval(59)))
        XCTAssertEqual(ActivityText.minutes(since: t0, now: t0.addingTimeInterval(61)), 1)
        XCTAssertEqual(ActivityText.minutes(since: t0, now: t0.addingTimeInterval(12 * 60 + 30)), 12)
    }
}
