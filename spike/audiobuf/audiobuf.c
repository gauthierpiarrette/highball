/* audiobuf: loaded into Wine's processes with DYLD_INSERT_LIBRARIES, it does four things.
 *
 * It caps the I/O buffer of each audio unit Wine starts at 5 ms (half of Wine's 10 ms shared-mode period). The device
 * otherwise moves its whole buffer at once, 512 frames, 10.7 ms at 48 kHz, more than a period. For output, a game that
 * keeps about one period queued (Counter-Strike 2) then had too little at most pulls and Wine played the rest as
 * silence (highball#127). For a microphone, Wine's capture ring holds the buffer the game asked for (three periods for
 * a short one) and Wine converts only while more than two periods are in it, so a 512-frame push did not fit and Wine
 * dropped the oldest 32 frames at nearly every period: 540 breaks in 6 s of a 48 kHz WASAPI capture with a 20 ms buffer,
 * 3 with the cap (highball#350). A capture unit takes the rate from its input side. Before, only a microphone on a
 * device that also has outputs got the cap, because the unit's output side was read, and that side has no format on a
 * microphone alone. The buffer size is per process and per device. The Wine 11 engine also carries the output cap in
 * its own winecoreaudio (highball-engine patch 0015).
 *
 * It limits float output like the last stage of Windows' audio engine (CAudioLimiter). Windows mixes shared-mode streams
 * in float and limits the result before the device, so a game may hand it samples above 1.0 and never clip. Wine passes
 * them to Core Audio, which clips them at the device: Paperback's title music reaches 1.33, 2.5 dB over full scale, in
 * 25 of 30 seconds (measured on an M4, highball-db#349), and loud passages sound harsh. After the unit renders, a
 * frame whose peak would pass 0.99 drops the gain at once to just below it, and the gain comes back toward 1 with a
 * 100 ms time constant. Below the threshold the gain is exactly 1, so sound under full scale passes bit for bit.
 *
 * It runs the clock Wine starts for each audio stream (audio_client_timer, which wakes the game every period) in real
 * time, as Windows runs its audio engine. Wine asks for THREAD_PRIORITY_TIME_CRITICAL, which the Wine 10 engines do not
 * pass on to macOS, and Wine 10 yields before each of the clock's sleeps. macOS's sched_yield drops the caller to
 * priority 0 until it runs again, so on a busy Mac the clock woke games late, up to 29 ms, and their sound ran dry
 * (highball#444). The Wine 11 engines run it at a fixed high priority, which a busy Mac still delayed.
 *
 * It keeps a game on the Mac's output when the Mac changes it. Wine binds each stream's unit to the device that was the
 * default when the stream opened and never listens for a change, so a game went on playing to the speakers after
 * AirPods connected (highball#460). The library listens for the change and moves each unit that was on Wine's default
 * to the new one, also a stream opened later, because Wine keeps the default its process started with. The device is
 * set on the running unit and the stream goes on after a gap of 0.3 to 0.5 s (measured on Wine 10, AirPods and a
 * MacBook's speakers). A unit on any other device stays there: the game picked it. Microphones stay where they are.
 *
 * HB_AUDIOLIMIT=0 turns the limiter off, HB_AUDIORT=0 the real-time clock, HB_AUDIOFOLLOW=0 the move to the Mac's new
 * output. HB_AUDIOBUF_DEBUG=1 logs each unit, each clock made real time, each move and, every 10 s of sound, the
 * frames limited.
 *
 * Shipped as an engine component, whose Wine has no source to patch for the Sikarugir builds.
 * Build: Scripts/build-audiobuf.sh */
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

/* A capture unit is one Wine made with output off on element 0 and input on element 1. Its device side is the input
 * scope of element 1, an output unit's is the output scope of element 0. */
static int is_capture(AudioUnit unit)
{
    UInt32 in_on = 0, out_on = 1, size = sizeof(UInt32);
    AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &in_on, &size);
    size = sizeof(UInt32);
    if (AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &out_on, &size) != noErr) out_on = 1;
    return in_on && !out_on;
}

static void cap_io_buffer(AudioUnit unit, int capture)
{
    AudioStreamBasicDescription hw;
    UInt32 hw_size = sizeof(hw), cur = 0, cur_size = sizeof(cur);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, capture ? kAudioUnitScope_Input : kAudioUnitScope_Output,
                             capture ? 1 : 0, &hw, &hw_size) == noErr
        && hw.mSampleRate > 0
        && AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &cur, &cur_size) == noErr) {
        UInt32 frames = (UInt32)(hw.mSampleRate * 0.005);
        if (frames > 0 && cur > frames) {
            OSStatus st = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, sizeof(frames));
            if (debug())
                fprintf(stderr, "audiobuf: %s I/O buffer %u -> %u frames at %.0f Hz, status %d\n", capture ? "capture" : "output",
                        (unsigned)cur, (unsigned)frames, hw.mSampleRate, (int)st);
        }
    }
}

static AudioUnit followers[MAX_UNITS];
static pthread_mutex_t followers_lock = PTHREAD_MUTEX_INITIALIZER;
static AudioDeviceID wine_default;      /* the default when this process first opened a stream, which Wine keeps using */

static AudioDeviceID default_output(void)
{
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev) == noErr ? dev : kAudioObjectUnknown;
}

static AudioDeviceID unit_device(AudioUnit unit)
{
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, &size);
    return dev;
}

static void move_unit(AudioUnit unit, AudioDeviceID to)
{
    AudioDeviceID from = unit_device(unit);
    if (to == kAudioObjectUnknown || from == to) return;
    OSStatus st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &to, sizeof(to));
    if (debug()) fprintf(stderr, "audiofollow: unit %p device %u -> %u, status %d\n", (void *)unit, (unsigned)from, (unsigned)to, (int)st);
    if (st == noErr) cap_io_buffer(unit, 0);                  /* the size is per device, and the new device starts at its own */
}

/* Runs on a queue of our own, so a move does not hold up Core Audio's notification thread. */
static void default_changed(void)
{
    AudioDeviceID to = default_output();
    pthread_mutex_lock(&followers_lock);
    for (int i = 0; i < MAX_UNITS; i++) if (followers[i]) move_unit(followers[i], to);
    pthread_mutex_unlock(&followers_lock);
}

static void follow_default(AudioUnit unit)
{
    const char *off = getenv("HB_AUDIOFOLLOW");
    if (off && off[0] == '0') return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        wine_default = default_output();
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &a, dispatch_queue_create("highball.audiofollow", NULL),
                                            ^(UInt32 n, const AudioObjectPropertyAddress *addrs) { default_changed(); });
    });
    if (unit_device(unit) != wine_default) return;
    pthread_mutex_lock(&followers_lock);
    for (int i = 0; i < MAX_UNITS; i++) if (!followers[i]) { followers[i] = unit; break; }
    move_unit(unit, default_output());                        /* a stream opened after a change starts on the new output */
    pthread_mutex_unlock(&followers_lock);
}

static OSStatus hb_AudioUnitInitialize(AudioUnit unit)
{
    int capture = is_capture(unit);
    if (!capture) follow_default(unit);
    cap_io_buffer(unit, capture);
    OSStatus r = AudioUnitInitialize(unit);
    if (r == noErr) add_limiter(unit);
    return r;
}

/* Wine disposes of a unit without uninitializing it. */
static OSStatus hb_AudioComponentInstanceDispose(AudioComponentInstance unit)
{
    pthread_mutex_lock(&followers_lock);
    for (int i = 0; i < MAX_UNITS; i++) if (followers[i] == unit) followers[i] = NULL;
    pthread_mutex_unlock(&followers_lock);
    return AudioComponentInstanceDispose(unit);
}

/* Wine starts one clock thread per audio stream, at THREAD_PRIORITY_TIME_CRITICAL, to wake the stream's client every
 * period, and the thread names itself audio_client_timer first thing. The policy asks for a slice every 10 ms (Wine's
 * shared-mode period) within that period. macOS 27 raises a smaller computation to half the constraint anyway (asked
 * for 2 ms, it reported 5). The thread blocks every period, so it never meets the kernel's limit for real-time threads
 * that run on, which would send it back to normal scheduling. */
static void make_realtime(void)
{
    mach_timebase_info_data_t tb;
    if (mach_timebase_info(&tb) != KERN_SUCCESS || !tb.numer) return;
    double per_ms = 1e6 * tb.denom / tb.numer;               /* Mach ticks per millisecond */
    thread_time_constraint_policy_data_t p = {
        .period = (uint32_t)(10 * per_ms),
        .computation = (uint32_t)(5 * per_ms),
        .constraint = (uint32_t)(10 * per_ms),
        .preemptible = 1,
    };
    kern_return_t kr = thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                                         (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (debug()) fprintf(stderr, "audiobuf: audio_client_timer real time, status %d\n", (int)kr);
}

static int hb_pthread_setname_np(const char *name)
{
    int r = pthread_setname_np(name);
    const char *off = getenv("HB_AUDIORT");
    if (name && !strcmp(name, "audio_client_timer") && !(off && off[0] == '0')) make_realtime();
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
    { (const void *)hb_AudioComponentInstanceDispose, (const void *)AudioComponentInstanceDispose },
    { (const void *)hb_pthread_setname_np, (const void *)pthread_setname_np },
};
