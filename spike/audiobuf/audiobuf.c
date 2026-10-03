/* audiobuf: loaded into Wine's processes with DYLD_INSERT_LIBRARIES, it caps an output audio
 * unit's I/O buffer at 5 ms (half of Wine's 10 ms shared-mode period) just before Wine starts the
 * unit. The device otherwise asks Wine's render callback for its whole buffer at once, 512 frames,
 * 10.7 ms at 48 kHz, and a game that keeps about one period queued (Counter-Strike 2) then had too
 * little at most pulls and Wine played the rest as silence (highball#127). The buffer size is per
 * process. Shipped as an engine component for the Sikarugir builds, whose Wine has no source to patch;
 * the Wine 11 engine carries the same cap in its own winecoreaudio (highball-engine patch 0015).
 * Build: Scripts/build-audiobuf.sh */
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>

static OSStatus hb_AudioUnitInitialize(AudioUnit unit)
{
    AudioStreamBasicDescription hw;
    UInt32 hw_size = sizeof(hw), cur = 0, cur_size = sizeof(cur);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hw, &hw_size) == noErr
        && hw.mSampleRate > 0
        && AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &cur, &cur_size) == noErr) {
        UInt32 frames = (UInt32)(hw.mSampleRate * 0.005);
        if (frames > 0 && cur > frames) {
            OSStatus st = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, sizeof(frames));
            if (getenv("HB_AUDIOBUF_DEBUG"))
                fprintf(stderr, "audiobuf: I/O buffer %u -> %u frames at %.0f Hz, status %d\n", (unsigned)cur, (unsigned)frames, hw.mSampleRate, (int)st);
        }
    }
    return AudioUnitInitialize(unit);
}

__attribute__((used)) static const struct { const void *replacement; const void *replacee; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)hb_AudioUnitInitialize, (const void *)AudioUnitInitialize },
};
