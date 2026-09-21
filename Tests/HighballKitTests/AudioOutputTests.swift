import XCTest
@testable import HighballKit

/// highball#127: "the music lags, like old computer speakers" took three rounds to get as far as
/// the Mac's output rate, because no log ever said what it was.
final class AudioOutputTests: XCTestCase {
    func testMatchingRateIsRecordedPlainly() {
        XCTAssertEqual(AudioOutput.headerLine(sampleRate: 48000), "# audio out=48000 Hz\n")
    }

    func testAMismatchSaysWhatItMeans() {
        let line = AudioOutput.headerLine(sampleRate: 44100)
        XCTAssertEqual(line, "# audio out=44100 Hz (games mix at 48000 Hz, so macOS resamples)\n")
    }

    func testNoDeviceAddsNoLine() {
        XCTAssertNil(AudioOutput.headerLine(sampleRate: nil))
    }

    func testTheRateOfThisMacIsPlausibleWhenThereIsOne() {
        guard let rate = AudioOutput.defaultOutputSampleRate() else { return }   // CI has no output device
        XCTAssertGreaterThanOrEqual(rate, 8000)
        XCTAssertLessThanOrEqual(rate, 768000)
    }
}
