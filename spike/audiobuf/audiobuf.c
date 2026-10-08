/* audiobuf: loaded into Wine's processes with DYLD_INSERT_LIBRARIES, it does two things to an output audio unit when
 * Wine starts it.
 *
 * It caps the unit's I/O buffer at 5 ms (half of Wine's 10 ms shared-mode period). The device otherwise asks Wine's
 * render callback for its whole buffer at once, 512 frames, 10.7 ms at 48 kHz, and a game that keeps about one period
 * queued (Counter-Strike 2) then had too little at most pulls and Wine played the rest as silence (highball#127). The
 * buffer size is per process. The Wine 11 engine carries the same cap in its own winecoreaudio (highball-engine patch
 * 0015).
 *
 * It limits float output like the last stage of Windows' audio engine (CAudioLimiter). Windows mixes shared-mode streams
 * in float and limits the result before the device, so a game may hand it samples above 1.0 and never clip. Wine passes
 * them to Core Audio, which clips them at the device: Paperback's title music reaches 1.33, 2.5 dB over full scale, in
 * 25 of 30 seconds (measured on an M4, highball-db#349), and loud passages sound harsh. After the unit renders, a
 * frame whose peak would pass 0.99 drops the gain at once to just below it, and the gain comes back toward 1 with a
 * 100 ms time constant. Below the threshold the gain is exactly 1, so sound under full scale passes bit for bit.
 * HB_AUDIOLIMIT=0 turns the limiter off. HB_AUDIOBUF_DEBUG=1 logs each unit and, every 10 s of sound, the frames limited.
 *
 * Shipped as an engine component, whose Wine has no source to patch for the Sikarugir builds.
 * Build: Scripts/build-audiobuf.sh */
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define MAX_UNITS 64
#define THRESHOLD 0.99f

typedef struct {
    AudioUnit unit;
    float gain, release;            /* current gain, per-frame release coefficient */
    UInt32 channels, interleaved;
    unsigned long long frames, limited, since_log;
    int added;
    float min_gain, peak;
    double rate;
} Limiter;

static Limiter limiters[MAX_UNITS];
static int debug_on = -1;

static int debug(void) { if (debug_on < 0) debug_on = getenv("HB_AUDIOBUF_DEBUG") != NULL; return debug_on; }

static Limiter *claim(AudioUnit unit)
{
    for (int i = 0; i < MAX_UNITS; i++) if (limiters[i].unit == unit) return &limiters[i];
    for (int i = 0; i < MAX_UNITS; i++)
        if (__sync_bool_compare_and_swap(&limiters[i].unit, NULL, unit)) return &limiters[i];
    return NULL;
}

static inline void limit_frame(Limiter *L, float **ch, UInt32 stride, UInt32 nch, UInt32 f)
{
    float peak = 0.0f;
    for (UInt32 c = 0; c < nch; c++) { float v = fabsf(ch[c][f * stride]); if (v > peak) peak = v; }
    if (peak > L->peak) L->peak = peak;
    if (peak * L->gain > THRESHOLD) L->gain = THRESHOLD / peak;          /* attack: at once, just enough */
    else if (L->gain < 1.0f) { L->gain += (1.0f - L->gain) * L->release; if (L->gain > 0.99999f) L->gain = 1.0f; }
    if (L->gain < 1.0f) {
        for (UInt32 c = 0; c < nch; c++) ch[c][f * stride] *= L->gain;
        L->limited++;
        if (L->gain < L->min_gain) L->min_gain = L->gain;
    }
}

static OSStatus notify(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *data)
{
    Limiter *L = ref;
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !frames) return noErr;   /* bus 1 is a capture */
    if (L->interleaved) {
        if (data->mNumberBuffers < 1 || !data->mBuffers[0].mData) return noErr;
        UInt32 nch = data->mBuffers[0].mNumberChannels; if (!nch || nch > 32) return noErr;
        float *base = data->mBuffers[0].mData, *ch[32];
        UInt32 n = data->mBuffers[0].mDataByteSize / (sizeof(float) * nch); if (n > frames) n = frames;
        for (UInt32 c = 0; c < nch; c++) ch[c] = base + c;
        for (UInt32 f = 0; f < n; f++) limit_frame(L, ch, nch, nch, f);
        L->frames += n; L->since_log += n;
    } else {
        UInt32 nch = data->mNumberBuffers; if (!nch || nch > 32) return noErr;
        float *ch[32]; UInt32 n = frames;
        for (UInt32 c = 0; c < nch; c++) {
            if (!data->mBuffers[c].mData) return noErr;
            ch[c] = data->mBuffers[c].mData;
            UInt32 m = data->mBuffers[c].mDataByteSize / sizeof(float); if (m < n) n = m;
        }
        for (UInt32 f = 0; f < n; f++) limit_frame(L, ch, 1, nch, f);
        L->frames += n; L->since_log += n;
    }
    if (debug() && L->since_log >= (unsigned long long)(L->rate * 10)) {
        fprintf(stderr, "audiolim: unit %p, %llu frames, %llu limited (%.2f%%), lowest gain %.3f, peak %.3f\n", (void *)L->unit,
                L->frames, L->limited, L->frames ? 100.0 * L->limited / L->frames : 0.0, L->min_gain, L->peak);
        L->since_log = 0; L->peak = 0.0f;
    }
    return noErr;
}

static void add_limiter(AudioUnit unit)
{
    const char *off = getenv("HB_AUDIOLIMIT");
    if (off && off[0] == '0') return;
    /* Output units only: a capture unit (Wine's microphone path) has output disabled on element 0. A unit that does
     * not answer (the default output unit) is output only. */
    UInt32 out_on = 1, out_size = sizeof(out_on);
    if (AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &out_on, &out_size) == noErr && !out_on) {
        if (debug()) fprintf(stderr, "audiolim: unit %p has no output (a capture), no limiter\n", (void *)unit);
        return;
    }
    AudioStreamBasicDescription f;
    UInt32 size = sizeof(f);
    /* What the unit's render produces: the output scope of element 0, the side the device takes. */
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, &size) != noErr) return;
    if (f.mFormatID != kAudioFormatLinearPCM || !(f.mFormatFlags & kAudioFormatFlagIsFloat) || f.mBitsPerChannel != 32) {
        if (debug()) fprintf(stderr, "audiolim: unit %p output is not 32-bit float (flags %x, %u bits), no limiter\n", (void *)unit, (unsigned)f.mFormatFlags, (unsigned)f.mBitsPerChannel);
        return;
    }
    Limiter *L = claim(unit);
    if (!L || L->added) return;
    L->gain = 1.0f; L->min_gain = 1.0f; L->peak = 0.0f; L->frames = L->limited = L->since_log = 0;
    L->rate = f.mSampleRate > 0 ? f.mSampleRate : 48000.0;
    L->release = 1.0f - expf(-1.0f / (0.1f * (float)L->rate));
    L->interleaved = !(f.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    L->channels = f.mChannelsPerFrame;
    OSStatus st = AudioUnitAddRenderNotify(unit, notify, L);
    L->added = st == noErr;
    if (debug()) fprintf(stderr, "audiolim: unit %p, %u channels %s at %.0f Hz, limiter %s (%d)\n", (void *)unit, (unsigned)f.mChannelsPerFrame,
                         L->interleaved ? "interleaved" : "planar", f.mSampleRate, st == noErr ? "on" : "failed", (int)st);
}

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
            if (debug())
                fprintf(stderr, "audiobuf: I/O buffer %u -> %u frames at %.0f Hz, status %d\n", (unsigned)cur, (unsigned)frames, hw.mSampleRate, (int)st);
        }
    }
    OSStatus r = AudioUnitInitialize(unit);
    if (r == noErr) add_limiter(unit);
    return r;
}

/* A unit that is uninitialized loses its limiter, so one initialized again (or a new unit at the same address) gets
 * exactly one. */
static OSStatus hb_AudioUnitUninitialize(AudioUnit unit)
{
    for (int i = 0; i < MAX_UNITS; i++)
        if (limiters[i].unit == unit) {
            if (limiters[i].added) AudioUnitRemoveRenderNotify(unit, notify, &limiters[i]);
            limiters[i].added = 0;
            __sync_synchronize();
            limiters[i].unit = NULL;
        }
    return AudioUnitUninitialize(unit);
}

__attribute__((used)) static const struct { const void *replacement; const void *replacee; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)hb_AudioUnitInitialize, (const void *)AudioUnitInitialize },
    { (const void *)hb_AudioUnitUninitialize, (const void *)AudioUnitUninitialize },
};
