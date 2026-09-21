import CoreAudio
import Foundation

/// The Mac's current output sample rate, for the launch header.
///
/// Windows games mix at 48 kHz and Wine hands that to macOS; when the output device runs at
/// 44.1 kHz something has to resample, and that is what people describe as crackling, or as an
/// old speaker about to take a call (highball#127, Counter-Strike 2, on the built-in speakers
/// and on AirPods alike). Nothing here changes a device — a Mac's audio settings are the
/// owner's — it only records the rate the session actually ran at, so a report about sound says
/// which side of that conversion it came from instead of costing three rounds of questions.
public enum AudioOutput {
    /// The default output device's sample rate in Hz, or nil when CoreAudio will not say (no
    /// output device, a sandbox without audio).
    public static func defaultOutputSampleRate() -> Double? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var device = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &device, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    /// What games mix at, and so the rate that needs no conversion.
    public static let gameSampleRate: Double = 48000

    /// The header line for a rate, or nil when there is nothing to record. Pure, so the wording
    /// is tested without an audio device.
    public static func headerLine(sampleRate: Double?) -> String? {
        guard let rate = sampleRate else { return nil }
        let hz = Int(rate.rounded())
        // The rate is the fact; what it means for a given crackle is the reader's to work out.
        // Crackling under Wine on a Mac is at least as often a winecoreaudio underrun as a
        // resample, so the header does not name a cause (highball#181 review).
        guard hz != Int(gameSampleRate) else { return "# audio out=\(hz) Hz\n" }
        return "# audio out=\(hz) Hz (most games mix at \(Int(gameSampleRate)) Hz)\n"
    }
}
