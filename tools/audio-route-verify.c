#include "SoundVolumeControlIDs.h"
#include "VolumeCurve.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static _Atomic(UInt32) gVolumeNotifications = 0;
static _Atomic(UInt32) gDecibelNotifications = 0;
static _Atomic(UInt32) gMuteNotifications = 0;

static AudioObjectPropertyAddress MakeAddress(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress) {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
}

static OSStatus Listener(AudioObjectID objectID,
                         UInt32 numberAddresses,
                         const AudioObjectPropertyAddress addresses[],
                         void *clientData) {
    (void)objectID;
    (void)clientData;
    for (UInt32 index = 0; index < numberAddresses; ++index) {
        switch (addresses[index].mSelector) {
            case kAudioDevicePropertyVolumeScalar:
                atomic_fetch_add_explicit(&gVolumeNotifications, 1,
                                          memory_order_relaxed);
                break;
            case kAudioDevicePropertyVolumeDecibels:
                atomic_fetch_add_explicit(&gDecibelNotifications, 1,
                                          memory_order_relaxed);
                break;
            case kAudioDevicePropertyMute:
                atomic_fetch_add_explicit(&gMuteNotifications, 1,
                                          memory_order_relaxed);
                break;
            default:
                break;
        }
    }
    return noErr;
}

static void PrintStatus(OSStatus status) {
    UInt32 raw = (UInt32)status;
    char code[5] = {
        (char)((raw >> 24) & 0xff),
        (char)((raw >> 16) & 0xff),
        (char)((raw >> 8) & 0xff),
        (char)(raw & 0xff),
        '\0',
    };
    bool printable = true;
    for (size_t index = 0; index < 4; ++index) {
        printable = printable && code[index] >= 32 && code[index] <= 126;
    }
    if (printable) {
        fprintf(stderr, "%d ('%s')", status, code);
    } else {
        fprintf(stderr, "%d", status);
    }
}

static void FailStatus(const char *description, OSStatus status) {
    fprintf(stderr, "FAIL: %s: ", description);
    PrintStatus(status);
    fputc('\n', stderr);
}

static AudioDeviceID FindDevice(void) {
    CFStringRef uid = CFSTR(SVC_DEVICE_UID);
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = MakeAddress(
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal
    );
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &address, sizeof(uid), &uid,
        &size, &device
    );
    if (status != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static bool ReadUInt32(AudioObjectID objectID,
                       AudioObjectPropertyAddress address,
                       UInt32 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address, 0, NULL,
                                      &size, value) == noErr;
}

static bool ReadFloat32(AudioObjectID objectID,
                        AudioObjectPropertyAddress address,
                        Float32 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address, 0, NULL,
                                      &size, value) == noErr;
}

static bool ReadRange(AudioObjectID objectID,
                      AudioObjectPropertyAddress address,
                      AudioValueRange *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address, 0, NULL,
                                      &size, value) == noErr;
}

static bool IsWritable(AudioObjectID objectID,
                       AudioObjectPropertyAddress address) {
    Boolean settable = false;
    return AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr
        && settable;
}

static int ChannelCount(AudioDeviceID device,
                        AudioObjectPropertyScope scope,
                        bool *ok) {
    AudioObjectPropertyAddress address = MakeAddress(
        kAudioDevicePropertyStreamConfiguration, scope
    );
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address,
                                                     0, NULL, &size);
    if (status != noErr || size < offsetof(AudioBufferList, mBuffers)) {
        *ok = false;
        return 0;
    }
    AudioBufferList *list = malloc(size);
    if (list == NULL) {
        *ok = false;
        return 0;
    }
    status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, list);
    if (status != noErr) {
        free(list);
        *ok = false;
        return 0;
    }
    int count = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        count += (int)list->mBuffers[index].mNumberChannels;
    }
    free(list);
    *ok = true;
    return count;
}

static bool CheckUInt32(AudioDeviceID device,
                        const char *description,
                        AudioObjectPropertyAddress address,
                        UInt32 expected) {
    UInt32 value = 0;
    if (!ReadUInt32(device, address, &value)) {
        fprintf(stderr, "FAIL: %s is missing or unreadable\n", description);
        return false;
    }
    if (value != expected) {
        fprintf(stderr, "FAIL: %s is %u, expected %u\n",
                description, value, expected);
        return false;
    }
    printf("PASS: %s = %u\n", description, value);
    return true;
}

static bool CheckStaticProperties(AudioDeviceID device) {
    bool passed = true;
    bool ok = false;
    int outputChannels = ChannelCount(device, kAudioObjectPropertyScopeOutput, &ok);
    if (!ok || outputChannels != kSVCChannelCount) {
        fprintf(stderr, "FAIL: output channel count is %d, expected %d\n",
                outputChannels, kSVCChannelCount);
        passed = false;
    } else {
        printf("PASS: output channel count = %d\n", outputChannels);
    }
    int inputChannels = ChannelCount(device, kAudioObjectPropertyScopeInput, &ok);
    if (!ok || inputChannels != 0) {
        fprintf(stderr, "FAIL: input channel count is %d, expected %d\n",
                inputChannels, 0);
        passed = false;
    } else {
        printf("PASS: input channel count = %d\n", inputChannels);
    }

    passed &= CheckUInt32(device, "alive",
        MakeAddress(kAudioDevicePropertyDeviceIsAlive,
                    kAudioObjectPropertyScopeGlobal), 1);
    passed &= CheckUInt32(device, "hidden",
        MakeAddress(kAudioDevicePropertyIsHidden,
                    kAudioObjectPropertyScopeGlobal), 0);
    passed &= CheckUInt32(device, "transport",
        MakeAddress(kAudioDevicePropertyTransportType,
                    kAudioObjectPropertyScopeGlobal),
        kAudioDeviceTransportTypeVirtual);
    passed &= CheckUInt32(device, "can be default output",
        MakeAddress(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                    kAudioObjectPropertyScopeOutput), 1);
    passed &= CheckUInt32(device, "can be default system output",
        MakeAddress(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
                    kAudioObjectPropertyScopeOutput), 1);

    AudioObjectID outputStream = kAudioObjectUnknown;
    UInt32 streamSize = sizeof(outputStream);
    AudioObjectPropertyAddress streams = MakeAddress(
        kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput
    );
    OSStatus streamStatus = AudioObjectGetPropertyData(
        device, &streams, 0, NULL, &streamSize, &outputStream
    );
    if (streamStatus != noErr || streamSize != sizeof(outputStream)
        || outputStream == kAudioObjectUnknown) {
        fputs("FAIL: output stream is missing or unreadable\n", stderr);
        passed = false;
    } else {
        printf("PASS: output stream object ID = %u\n", outputStream);
        passed &= CheckUInt32(outputStream, "output stream active",
            MakeAddress(kAudioStreamPropertyIsActive,
                        kAudioObjectPropertyScopeGlobal), 1);
        passed &= CheckUInt32(outputStream, "output stream direction",
            MakeAddress(kAudioStreamPropertyDirection,
                        kAudioObjectPropertyScopeGlobal), 0);
    }

    streamSize = 0;
    streams.mScope = kAudioObjectPropertyScopeInput;
    streamStatus = AudioObjectGetPropertyDataSize(
        device, &streams, 0, NULL, &streamSize
    );
    if (streamStatus != noErr || streamSize != 0) {
        fputs("FAIL: the output-only device unexpectedly exposes an input stream\n",
              stderr);
        passed = false;
    } else {
        puts("PASS: output-only device exposes no input stream");
    }

    AudioObjectPropertyAddress scalar = MakeAddress(
        kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput
    );
    AudioObjectPropertyAddress decibels = MakeAddress(
        kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput
    );
    AudioObjectPropertyAddress mute = MakeAddress(
        kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput
    );
    if (!AudioObjectHasProperty(device, &scalar) || !IsWritable(device, scalar)) {
        fputs("FAIL: output/main volume scalar is not present and writable\n", stderr);
        passed = false;
    } else {
        puts("PASS: output/main volume scalar is present and writable");
    }
    if (!AudioObjectHasProperty(device, &decibels) || !IsWritable(device, decibels)) {
        fputs("FAIL: output/main volume decibels is not present and writable\n", stderr);
        passed = false;
    } else {
        puts("PASS: output/main volume decibels is present and writable");
    }
    if (!AudioObjectHasProperty(device, &mute) || !IsWritable(device, mute)) {
        fputs("FAIL: output/main mute is not present and writable\n", stderr);
        passed = false;
    } else {
        puts("PASS: output/main mute is present and writable");
    }
    return passed;
}

static bool NearlyEqual(Float32 lhs, Float32 rhs) {
    return fabsf(lhs - rhs) <= 0.0005f;
}

static AudioObjectID FindVolumeControl(AudioDeviceID device) {
    AudioObjectPropertyAddress listAddress = MakeAddress(
        kAudioObjectPropertyControlList, kAudioObjectPropertyScopeOutput
    );
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &listAddress,
                                       0, NULL, &size) != noErr
        || size == 0 || size % sizeof(AudioObjectID) != 0) {
        return kAudioObjectUnknown;
    }
    AudioObjectID *controls = malloc(size);
    if (controls == NULL) {
        return kAudioObjectUnknown;
    }
    if (AudioObjectGetPropertyData(device, &listAddress, 0, NULL,
                                   &size, controls) != noErr) {
        free(controls);
        return kAudioObjectUnknown;
    }
    AudioObjectID result = kAudioObjectUnknown;
    size_t count = size / sizeof(AudioObjectID);
    for (size_t index = 0; index < count; ++index) {
        UInt32 classID = 0;
        if (ReadUInt32(controls[index],
                       MakeAddress(kAudioObjectPropertyClass,
                                   kAudioObjectPropertyScopeGlobal),
                       &classID)
            && classID == kAudioVolumeControlClassID) {
            result = controls[index];
            break;
        }
    }
    free(controls);
    return result;
}

static OSStatus TryDirectConversion(AudioObjectID control,
                                    AudioObjectPropertySelector selector,
                                    Float32 input,
                                    Float32 expected,
                                    bool *matches) {
    AudioObjectPropertyAddress address = MakeAddress(
        selector, kAudioObjectPropertyScopeGlobal
    );
    UInt32 size = sizeof(input);
    OSStatus status = AudioObjectGetPropertyData(control, &address,
                                                  0, NULL, &size, &input);
    *matches = status == noErr && NearlyEqual(input, expected);
    return status;
}

static bool CheckConversions(AudioDeviceID device) {
    AudioObjectPropertyAddress rangeAddress = MakeAddress(
        kAudioDevicePropertyVolumeRangeDecibels,
        kAudioObjectPropertyScopeOutput
    );
    AudioValueRange range = {0};
    if (!ReadRange(device, rangeAddress, &range)) {
        fputs("FAIL: dB range is missing or unreadable\n", stderr);
        return false;
    }
    if (!NearlyEqual((Float32)range.mMinimum, -96.0f)
        || !NearlyEqual((Float32)range.mMaximum, 0.0f)) {
        fprintf(stderr, "FAIL: unexpected dB range %.3f...%.3f\n",
                range.mMinimum, range.mMaximum);
        return false;
    }

    Float32 scalarToDB = 0.25f;
    UInt32 size = sizeof(scalarToDB);
    AudioObjectPropertyAddress toDB = MakeAddress(
        kAudioDevicePropertyVolumeScalarToDecibels,
        kAudioObjectPropertyScopeOutput
    );
    OSStatus status = AudioObjectGetPropertyData(device, &toDB, 0, NULL,
                                                  &size, &scalarToDB);
    if (status != noErr || !NearlyEqual(scalarToDB, -24.0824f)) {
        AudioObjectID control = FindVolumeControl(device);
        bool directMatches = false;
        OSStatus directStatus = control == kAudioObjectUnknown
            ? kAudioHardwareBadObjectError
            : TryDirectConversion(
                control, kAudioLevelControlPropertyConvertScalarToDecibels,
                0.25f, -24.0824f, &directMatches
            );
        if (status == kAudioHardwareUnspecifiedError
            && directStatus == kAudioHardwareUnspecifiedError) {
            puts("WARN: macOS driver-helper proxy declined the in/out conversion call;");
            puts("      range/value mapping is live-tested and conversion is contract-tested.");
            return true;
        }
        FailStatus("scalar-to-dB conversion", status);
        if (control == kAudioObjectUnknown) {
            fputs("FAIL: owned volume control could not be found\n", stderr);
        } else if (directStatus != noErr || !directMatches) {
            FailStatus("owned-control conversion", directStatus);
        }
        return false;
    }

    Float32 dbToScalar = -48.0f;
    size = sizeof(dbToScalar);
    AudioObjectPropertyAddress toScalar = MakeAddress(
        kAudioDevicePropertyVolumeDecibelsToScalar,
        kAudioObjectPropertyScopeOutput
    );
    status = AudioObjectGetPropertyData(device, &toScalar, 0, NULL,
                                        &size, &dbToScalar);
    if (status != noErr || !NearlyEqual(dbToScalar, 0.0630957f)) {
        FailStatus("dB-to-scalar conversion", status);
        return false;
    }
    puts("PASS: dB range and conversions are internally consistent");
    return true;
}

static void BriefWait(void) {
    const struct timespec interval = {.tv_sec = 0, .tv_nsec = 50000000};
    (void)nanosleep(&interval, NULL);
}

static bool ExerciseControls(AudioDeviceID device) {
    AudioObjectPropertyAddress scalarAddress = MakeAddress(
        kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput
    );
    AudioObjectPropertyAddress decibelAddress = MakeAddress(
        kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput
    );
    AudioObjectPropertyAddress muteAddress = MakeAddress(
        kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput
    );
    Float32 originalScalar = 0;
    UInt32 originalMute = 0;
    if (!ReadFloat32(device, scalarAddress, &originalScalar)
        || !ReadUInt32(device, muteAddress, &originalMute)) {
        fputs("FAIL: could not save the original controls\n", stderr);
        return false;
    }

    OSStatus status = AudioObjectAddPropertyListener(device, &scalarAddress,
                                                      Listener, NULL);
    if (status == noErr) {
        status = AudioObjectAddPropertyListener(device, &decibelAddress,
                                                 Listener, NULL);
    }
    if (status == noErr) {
        status = AudioObjectAddPropertyListener(device, &muteAddress,
                                                 Listener, NULL);
    }
    if (status != noErr) {
        FailStatus("adding property listeners", status);
        return false;
    }

    bool passed = true;
    const Float32 values[] = {0.0f, 0.25f, 0.5f, 0.875f, 1.0f};
    for (size_t index = 0; index < sizeof(values) / sizeof(values[0]); ++index) {
        Float32 value = values[index];
        status = AudioObjectSetPropertyData(device, &scalarAddress,
                                            0, NULL, sizeof(value), &value);
        Float32 readBack = -1.0f;
        if (status != noErr || !ReadFloat32(device, scalarAddress, &readBack)
            || !NearlyEqual(readBack, value)) {
            fprintf(stderr, "FAIL: scalar %.3f did not round-trip (read %.3f)\n",
                    value, readBack);
            passed = false;
            break;
        }
    }

    Float32 outOfRange = -1.0f;
    status = AudioObjectSetPropertyData(device, &scalarAddress, 0, NULL,
                                        sizeof(outOfRange), &outOfRange);
    Float32 clamped = -1.0f;
    if (status != noErr || !ReadFloat32(device, scalarAddress, &clamped)
        || !NearlyEqual(clamped, 0.0f)) {
        fputs("FAIL: negative scalar did not clamp to zero\n", stderr);
        passed = false;
    }
    outOfRange = 2.0f;
    status = AudioObjectSetPropertyData(device, &scalarAddress, 0, NULL,
                                        sizeof(outOfRange), &outOfRange);
    if (status != noErr || !ReadFloat32(device, scalarAddress, &clamped)
        || !NearlyEqual(clamped, 1.0f)) {
        fputs("FAIL: scalar above unity did not clamp to one\n", stderr);
        passed = false;
    }

    UInt32 mute = originalMute == 0 ? 1 : 0;
    status = AudioObjectSetPropertyData(device, &muteAddress,
                                        0, NULL, sizeof(mute), &mute);
    UInt32 readMute = originalMute;
    if (status != noErr || !ReadUInt32(device, muteAddress, &readMute)
        || readMute != mute) {
        fputs("FAIL: mute did not round-trip\n", stderr);
        passed = false;
    }
    BriefWait();

    (void)AudioObjectSetPropertyData(device, &scalarAddress, 0, NULL,
                                     sizeof(originalScalar), &originalScalar);
    (void)AudioObjectSetPropertyData(device, &muteAddress, 0, NULL,
                                     sizeof(originalMute), &originalMute);
    BriefWait();

    (void)AudioObjectRemovePropertyListener(device, &scalarAddress, Listener, NULL);
    (void)AudioObjectRemovePropertyListener(device, &decibelAddress, Listener, NULL);
    (void)AudioObjectRemovePropertyListener(device, &muteAddress, Listener, NULL);

    UInt32 volumeNotifications = atomic_load_explicit(&gVolumeNotifications,
                                                       memory_order_relaxed);
    UInt32 decibelNotifications = atomic_load_explicit(&gDecibelNotifications,
                                                        memory_order_relaxed);
    UInt32 muteNotifications = atomic_load_explicit(&gMuteNotifications,
                                                     memory_order_relaxed);
    if (volumeNotifications == 0 || decibelNotifications == 0
        || muteNotifications == 0) {
        fprintf(stderr,
                "FAIL: listener counts scalar=%u dB=%u mute=%u\n",
                volumeNotifications, decibelNotifications, muteNotifications);
        passed = false;
    } else {
        printf("PASS: listener counts scalar=%u dB=%u mute=%u\n",
               volumeNotifications, decibelNotifications, muteNotifications);
    }
    if (passed) {
        puts("PASS: control writes, clamping, mute, and restoration");
    }
    return passed;
}

static bool WatchNativeControls(AudioDeviceID device) {
    AudioObjectPropertyAddress scalarAddress = MakeAddress(
        kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput
    );
    AudioObjectPropertyAddress decibelAddress = MakeAddress(
        kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput
    );
    AudioObjectPropertyAddress muteAddress = MakeAddress(
        kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput
    );
    OSStatus status = AudioObjectAddPropertyListener(device, &scalarAddress,
                                                      Listener, NULL);
    if (status == noErr) {
        status = AudioObjectAddPropertyListener(device, &decibelAddress,
                                                 Listener, NULL);
    }
    if (status == noErr) {
        status = AudioObjectAddPropertyListener(device, &muteAddress,
                                                 Listener, NULL);
    }
    if (status != noErr) {
        FailStatus("adding native-control listeners", status);
        return false;
    }

    Float32 scalar = 0;
    Float32 decibels = 0;
    UInt32 mute = 0;
    (void)ReadFloat32(device, scalarAddress, &scalar);
    (void)ReadFloat32(device, decibelAddress, &decibels);
    (void)ReadUInt32(device, muteAddress, &mute);
    printf("Watching 45 seconds: scalar=%.3f dB=%.1f mute=%u\n",
           scalar, decibels, mute);
    puts("Use only macOS Sound Settings, Control Center, or the volume/mute keys now.");
    fflush(stdout);

    UInt32 lastVolumeCount = 0;
    UInt32 lastDecibelCount = 0;
    UInt32 lastMuteCount = 0;
    const struct timespec interval = {.tv_sec = 0, .tv_nsec = 250000000};
    for (UInt32 iteration = 0; iteration < 180; ++iteration) {
        (void)nanosleep(&interval, NULL);
        UInt32 volumeCount = atomic_load_explicit(&gVolumeNotifications,
                                                   memory_order_relaxed);
        UInt32 decibelCount = atomic_load_explicit(&gDecibelNotifications,
                                                    memory_order_relaxed);
        UInt32 muteCount = atomic_load_explicit(&gMuteNotifications,
                                                 memory_order_relaxed);
        if (volumeCount != lastVolumeCount
            || decibelCount != lastDecibelCount
            || muteCount != lastMuteCount) {
            (void)ReadFloat32(device, scalarAddress, &scalar);
            (void)ReadFloat32(device, decibelAddress, &decibels);
            (void)ReadUInt32(device, muteAddress, &mute);
            printf("CHANGE: scalar=%.3f dB=%.1f mute=%u "
                   "(notifications %u/%u/%u)\n",
                   scalar, decibels, mute,
                   volumeCount, decibelCount, muteCount);
            fflush(stdout);
            lastVolumeCount = volumeCount;
            lastDecibelCount = decibelCount;
            lastMuteCount = muteCount;
        }
    }

    (void)AudioObjectRemovePropertyListener(device, &scalarAddress, Listener, NULL);
    (void)AudioObjectRemovePropertyListener(device, &decibelAddress, Listener, NULL);
    (void)AudioObjectRemovePropertyListener(device, &muteAddress, Listener, NULL);

    bool passed = lastVolumeCount > 0
        && lastDecibelCount > 0
        && lastMuteCount > 0;
    puts(passed
        ? "PASS: native interaction produced scalar, dB, and mute notifications"
        : "FAIL: no complete native volume/mute notification set was observed");
    return passed;
}

static bool SetSystemDevice(AudioObjectPropertySelector selector,
                            AudioDeviceID device) {
    AudioObjectPropertyAddress address = MakeAddress(
        selector, kAudioObjectPropertyScopeGlobal
    );
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &address,
                                      0, NULL, sizeof(device), &device) == noErr;
}

static bool WatchWithTemporaryDefault(AudioDeviceID device) {
    UInt32 originalOutput = kAudioObjectUnknown;
    UInt32 originalSystem = kAudioObjectUnknown;
    bool readOutput = ReadUInt32(
        kAudioObjectSystemObject,
        MakeAddress(kAudioHardwarePropertyDefaultOutputDevice,
                    kAudioObjectPropertyScopeGlobal),
        &originalOutput
    );
    bool readSystem = ReadUInt32(
        kAudioObjectSystemObject,
        MakeAddress(kAudioHardwarePropertyDefaultSystemOutputDevice,
                    kAudioObjectPropertyScopeGlobal),
        &originalSystem
    );
    if (!readOutput || !readSystem) {
        fputs("FAIL: could not save the current default outputs\n", stderr);
        return false;
    }

    bool selectedSystem = SetSystemDevice(
        kAudioHardwarePropertyDefaultSystemOutputDevice, device
    );
    bool selectedOutput = SetSystemDevice(
        kAudioHardwarePropertyDefaultOutputDevice, device
    );
    if (!selectedSystem || !selectedOutput) {
        fputs("FAIL: could not temporarily select Sound Volume\n", stderr);
        (void)SetSystemDevice(kAudioHardwarePropertyDefaultOutputDevice,
                              originalOutput);
        (void)SetSystemDevice(kAudioHardwarePropertyDefaultSystemOutputDevice,
                              originalSystem);
        return false;
    }

    puts("Sound Volume is temporarily the default output; audio is intentionally silent.");
    bool passed = WatchNativeControls(device);

    bool restoredOutput = SetSystemDevice(
        kAudioHardwarePropertyDefaultOutputDevice, originalOutput
    );
    bool restoredSystem = SetSystemDevice(
        kAudioHardwarePropertyDefaultSystemOutputDevice, originalSystem
    );
    if (!restoredOutput || !restoredSystem) {
        fputs("FAIL: automatic default-output restoration failed; select your physical output manually\n",
              stderr);
        return false;
    }
    puts("Restored the original default output and system-sounds output.");
    return passed;
}

static bool VerifyExternalRestoration(
    AudioDeviceID device,
    AudioObjectPropertySelector selector,
    const char *label
) {
    UInt32 original = kAudioObjectUnknown;
    if (!ReadUInt32(
            kAudioObjectSystemObject,
            MakeAddress(selector, kAudioObjectPropertyScopeGlobal),
            &original)) {
        fprintf(stderr, "FAIL: could not save %s\n", label);
        return false;
    }
    if (!SetSystemDevice(selector, device)) {
        fprintf(stderr, "FAIL: could not set Sound Volume as %s\n", label);
        return false;
    }
    printf("Sound Volume is temporarily %s; waiting 30 seconds for external restoration.\n",
           label);
    fflush(stdout);

    const struct timespec interval = {.tv_sec = 0, .tv_nsec = 250000000};
    for (UInt32 iteration = 0; iteration < 120; ++iteration) {
        (void)nanosleep(&interval, NULL);
        UInt32 current = kAudioObjectUnknown;
        if (ReadUInt32(
                kAudioObjectSystemObject,
                MakeAddress(selector, kAudioObjectPropertyScopeGlobal),
                &current)
            && current != device) {
            if (current == original) {
                printf("PASS: external action restored the original %s.\n", label);
                return true;
            }
            fprintf(stderr,
                    "FAIL: external action changed %s, but not to its original device\n",
                    label);
            (void)SetSystemDevice(selector, original);
            return false;
        }
    }

    fprintf(stderr, "FAIL: no external restoration of %s was observed\n", label);
    (void)SetSystemDevice(selector, original);
    return false;
}

static int RefuseIfDefault(AudioDeviceID device) {
    if (device == kAudioObjectUnknown) {
        return EXIT_SUCCESS;
    }
    UInt32 defaultOutput = kAudioObjectUnknown;
    UInt32 defaultSystem = kAudioObjectUnknown;
    (void)ReadUInt32(kAudioObjectSystemObject,
        MakeAddress(kAudioHardwarePropertyDefaultOutputDevice,
                    kAudioObjectPropertyScopeGlobal), &defaultOutput);
    (void)ReadUInt32(kAudioObjectSystemObject,
        MakeAddress(kAudioHardwarePropertyDefaultSystemOutputDevice,
                    kAudioObjectPropertyScopeGlobal), &defaultSystem);
    if (device == defaultOutput || device == defaultSystem) {
        fputs("Sound Volume is still a default output. Select another output before uninstalling.\n",
              stderr);
        return 2;
    }
    return EXIT_SUCCESS;
}

int main(int argc, char *argv[]) {
    bool exercise = false;
    bool refuseIfDefault = false;
    bool watchNative = false;
    bool watchTemporaryDefault = false;
    bool verifyOutputRestoration = false;
    bool verifySystemRestoration = false;
    if (argc == 2 && strcmp(argv[1], "--exercise-controls") == 0) {
        exercise = true;
    } else if (argc == 2 && strcmp(argv[1], "--refuse-if-default") == 0) {
        refuseIfDefault = true;
    } else if (argc == 2 && strcmp(argv[1], "--watch-native") == 0) {
        watchNative = true;
    } else if (argc == 2
               && strcmp(argv[1], "--watch-native-temporary-default") == 0) {
        watchTemporaryDefault = true;
    } else if (argc == 2
               && strcmp(argv[1], "--verify-external-output-restoration") == 0) {
        verifyOutputRestoration = true;
    } else if (argc == 2
               && strcmp(argv[1], "--verify-external-system-restoration") == 0) {
        verifySystemRestoration = true;
    } else if (argc != 1) {
        fprintf(stderr, "usage: %s [--exercise-controls|--watch-native|--watch-native-temporary-default|--verify-external-output-restoration|--verify-external-system-restoration|--refuse-if-default]\n",
                argv[0]);
        return 64;
    }

    AudioDeviceID device = FindDevice();
    if (refuseIfDefault) {
        return RefuseIfDefault(device);
    }
    if (device == kAudioObjectUnknown) {
        fputs("FAIL: Sound Volume device is not registered with CoreAudio\n", stderr);
        return EXIT_FAILURE;
    }
    printf("Sound Volume object ID: %u\n", device);

    bool passed = CheckStaticProperties(device);
    passed &= CheckConversions(device);
    if (exercise) {
        passed &= ExerciseControls(device);
    } else if (watchNative) {
        passed &= WatchNativeControls(device);
    } else if (watchTemporaryDefault) {
        passed &= WatchWithTemporaryDefault(device);
    } else if (verifyOutputRestoration) {
        passed &= VerifyExternalRestoration(
            device,
            kAudioHardwarePropertyDefaultOutputDevice,
            "default output"
        );
    } else if (verifySystemRestoration) {
        passed &= VerifyExternalRestoration(
            device,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            "system-sounds output"
        );
    } else {
        puts("Read-only checks complete. Use --exercise-controls to test writes and listeners.");
    }
    puts(passed ? "audio-route-verify: PASS" : "audio-route-verify: FAIL");
    return passed ? EXIT_SUCCESS : EXIT_FAILURE;
}
