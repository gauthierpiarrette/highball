/* Check for audiobuf's move to the Mac's new output (highball#460). Flips the default output to another device and
 * back, restores it, and plays silence, so nothing is heard. Needs two output devices.
 * clang -o /tmp/follow-check spike/audiobuf/follow-check.c -framework AudioToolbox -framework CoreAudio
 * DYLD_INSERT_LIBRARIES=dist/audiobuf/libhbaudiobuf.dylib /tmp/follow-check */
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static AudioObjectPropertyAddress addr(UInt32 sel, UInt32 scope) { AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain }; return a; }

static AudioDeviceID get_default(void)
{
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioDeviceID d = 0; UInt32 z = sizeof(d);
    assert(!AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &z, &d));
    return d;
}

static void set_default(AudioDeviceID d)
{
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    assert(!AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof(d), &d));
    usleep(1500000);
}

static AudioDeviceID other_output(AudioDeviceID not_this)
{
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    AudioDeviceID ids[64]; UInt32 z = sizeof(ids);
    assert(!AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &z, ids));
    for (unsigned i = 0; i < z / sizeof(ids[0]); i++) {
        AudioObjectPropertyAddress s = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
        UInt32 q = 0;
        AudioObjectGetPropertyDataSize(ids[i], &s, 0, NULL, &q);
        if (q && ids[i] != not_this) return ids[i];
    }
    return 0;
}

static volatile unsigned long calls;
static OSStatus silence(void *u, AudioUnitRenderActionFlags *f, const AudioTimeStamp *t, UInt32 b, UInt32 n, AudioBufferList *d)
{
    calls++;
    for (UInt32 i = 0; i < d->mNumberBuffers; i++) memset(d->mBuffers[i].mData, 0, d->mBuffers[i].mDataByteSize);
    return noErr;
}

/* A unit set up the way Wine's get_audiounit and ca_setup_audiounit do it. */
static AudioUnit open_unit(AudioDeviceID dev)
{
    AudioComponentDescription d = { kAudioUnitType_Output, kAudioUnitSubType_HALOutput, 0, kAudioUnitManufacturer_Apple, 0 };
    AudioUnit u;
    assert(!AudioComponentInstanceNew(AudioComponentFindNext(NULL, &d), &u));
    assert(!AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, sizeof(dev)));
    AudioStreamBasicDescription f = { 48000, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0 };
    assert(!AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f)));
    AURenderCallbackStruct r = { silence, NULL };
    assert(!AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &r, sizeof(r)));
    assert(!AudioUnitInitialize(u));
    assert(!AudioOutputUnitStart(u));
    return u;
}

static AudioDeviceID device_of(AudioUnit u)
{
    AudioDeviceID d = 0; UInt32 z = sizeof(d);
    assert(!AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, &z));
    return d;
}

int main(void)
{
    AudioDeviceID home = get_default(), away = other_output(home);
    assert(away);
    AudioUnit follows = open_unit(home), pinned = open_unit(away);   /* the game picked "away" while it was not the default */
    usleep(500000);

    set_default(away);
    int moved = device_of(follows) == away;
    unsigned long before = calls;
    usleep(500000);
    int plays = calls > before;
    AudioUnit late = open_unit(home);                                /* Wine's stale default, opened after the change */
    usleep(500000);
    int late_moved = device_of(late) == away;

    set_default(home);
    int back = device_of(follows) == home && device_of(late) == home;
    int stayed = device_of(pinned) == away;
    AudioOutputUnitStop(late); AudioComponentInstanceDispose(late);
    set_default(away);                                               /* a disposed unit must not be touched */
    set_default(home);
    AudioOutputUnitStop(follows); AudioComponentInstanceDispose(follows);
    AudioOutputUnitStop(pinned); AudioComponentInstanceDispose(pinned);

    printf("moved %d, plays after the move %d, stream opened later moved %d, back %d, pinned stayed %d, default restored %d\n",
           moved, plays, late_moved, back, stayed, get_default() == home);
    assert(moved && plays && late_moved && back && stayed && get_default() == home);
    puts("ok");
    return 0;
}
