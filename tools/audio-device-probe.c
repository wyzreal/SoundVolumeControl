#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static const AudioObjectID kSystemObject = kAudioObjectSystemObject;

static AudioObjectPropertyAddress MakeAddress(AudioObjectPropertySelector selector,
                                              AudioObjectPropertyScope scope,
                                              AudioObjectPropertyElement element) {
    return (AudioObjectPropertyAddress) {
        .mSelector = selector,
        .mScope = scope,
        .mElement = element,
    };
}

static void PrintStatus(OSStatus status) {
    uint32_t raw = (uint32_t)status;
    char code[5] = {
        (char)((raw >> 24) & 0xff),
        (char)((raw >> 16) & 0xff),
        (char)((raw >> 8) & 0xff),
        (char)(raw & 0xff),
        '\0',
    };
    bool printable = true;
    for (size_t i = 0; i < 4; ++i) {
        printable = printable && code[i] >= 32 && code[i] <= 126;
    }
    if (printable) {
        fprintf(stderr, "%d ('%s')", status, code);
    } else {
        fprintf(stderr, "%d", status);
    }
}

static bool HasProperty(AudioObjectID objectID, AudioObjectPropertyAddress address) {
    return AudioObjectHasProperty(objectID, &address);
}

static bool IsSettable(AudioObjectID objectID,
                       AudioObjectPropertyAddress address,
                       bool *result) {
    Boolean settable = false;
    OSStatus status = AudioObjectIsPropertySettable(objectID, &address, &settable);
    if (status != noErr) {
        return false;
    }
    *result = settable;
    return true;
}

static bool ReadUInt32(AudioObjectID objectID,
                       AudioObjectPropertyAddress address,
                       UInt32 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size, value) == noErr;
}

static bool ReadFloat32(AudioObjectID objectID,
                        AudioObjectPropertyAddress address,
                        Float32 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size, value) == noErr;
}

static bool ReadString(AudioObjectID objectID,
                       AudioObjectPropertyAddress address,
                       char *buffer,
                       CFIndex bufferSize) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        NULL,
        &size,
        &value
    );
    if (status != noErr || value == NULL) {
        return false;
    }

    Boolean converted = CFStringGetCString(value, buffer, bufferSize, kCFStringEncodingUTF8);
    CFRelease(value);
    return converted;
}

static int ChannelCount(AudioDeviceID deviceID, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = MakeAddress(
        kAudioDevicePropertyStreamConfiguration,
        scope,
        kAudioObjectPropertyElementMain
    );
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL, &size);
    if (status != noErr || size < sizeof(AudioBufferList)) {
        return 0;
    }

    AudioBufferList *list = malloc(size);
    if (list == NULL) {
        return 0;
    }
    status = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, list);
    if (status != noErr) {
        free(list);
        return 0;
    }

    int channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        channels += (int)list->mBuffers[i].mNumberChannels;
    }
    free(list);
    return channels;
}

static void FourCC(UInt32 value, char result[5]) {
    result[0] = (char)((value >> 24) & 0xff);
    result[1] = (char)((value >> 16) & 0xff);
    result[2] = (char)((value >> 8) & 0xff);
    result[3] = (char)(value & 0xff);
    result[4] = '\0';
    for (size_t i = 0; i < 4; ++i) {
        if (result[i] < 32 || result[i] > 126) {
            result[i] = '?';
        }
    }
}

static const char *YesNoKnown(bool known, bool value) {
    return known ? (value ? "yes" : "no") : "unknown";
}

static void PrintScalar(AudioDeviceID deviceID, AudioObjectPropertyElement element) {
    AudioObjectPropertyAddress address = MakeAddress(
        kAudioDevicePropertyVolumeScalar,
        kAudioObjectPropertyScopeOutput,
        element
    );
    if (!HasProperty(deviceID, address)) {
        printf("absent");
        return;
    }

    bool settable = false;
    bool knowsSettable = IsSettable(deviceID, address, &settable);
    Float32 value = 0;
    if (ReadFloat32(deviceID, address, &value)) {
        printf("%.6f (%s)", value,
               knowsSettable ? (settable ? "writable" : "read-only")
                              : "settable-query-failed");
    } else {
        printf("present, unreadable (%s)",
               knowsSettable ? (settable ? "writable" : "read-only")
                              : "settable-query-failed");
    }
}

static void PrintMute(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress address = MakeAddress(
        kAudioDevicePropertyMute,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    );
    if (!HasProperty(deviceID, address)) {
        printf("absent");
        return;
    }

    bool settable = false;
    bool knowsSettable = IsSettable(deviceID, address, &settable);
    UInt32 value = 0;
    if (ReadUInt32(deviceID, address, &value)) {
        printf("%s (%s)", value == 0 ? "off" : "on",
               knowsSettable ? (settable ? "writable" : "read-only")
                              : "settable-query-failed");
    } else {
        printf("present, unreadable (%s)",
               knowsSettable ? (settable ? "writable" : "read-only")
                              : "settable-query-failed");
    }
}

static void PrintVolumeConversions(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress rangeAddress = MakeAddress(
        kAudioDevicePropertyVolumeRangeDecibels,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    );
    AudioValueRange range = {0};
    UInt32 size = sizeof(range);
    OSStatus rangeStatus = AudioObjectGetPropertyData(
        deviceID, &rangeAddress, 0, NULL, &size, &range
    );
    if (rangeStatus != noErr) {
        printf("unavailable (range status %d)", rangeStatus);
        return;
    }

    AudioObjectPropertyAddress toDBAddress = MakeAddress(
        kAudioDevicePropertyVolumeScalarToDecibels,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    );
    Float32 converted = 0.5f;
    size = sizeof(converted);
    OSStatus conversionStatus = AudioObjectGetPropertyData(
        deviceID, &toDBAddress, 0, NULL, &size, &converted
    );
    if (conversionStatus != noErr) {
        printf("range %.1f...%.1f dB; conversion status %d",
               range.mMinimum, range.mMaximum, conversionStatus);
        return;
    }
    printf("range %.1f...%.1f dB; scalar 0.5 -> %.1f dB",
           range.mMinimum, range.mMaximum, converted);
}

static bool NativeVolumeCandidate(AudioDeviceID deviceID, int outputChannels) {
    AudioObjectPropertyAddress mainAddress = MakeAddress(
        kAudioDevicePropertyVolumeScalar,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    );
    bool settable = false;
    if (HasProperty(deviceID, mainAddress)
        && IsSettable(deviceID, mainAddress, &settable)
        && settable) {
        return true;
    }

    if (outputChannels <= 0) {
        return false;
    }
    for (int channel = 1; channel <= outputChannels; ++channel) {
        AudioObjectPropertyAddress channelAddress = MakeAddress(
            kAudioDevicePropertyVolumeScalar,
            kAudioObjectPropertyScopeOutput,
            (AudioObjectPropertyElement)channel
        );
        settable = false;
        if (!HasProperty(deviceID, channelAddress)
            || !IsSettable(deviceID, channelAddress, &settable)
            || !settable) {
            return false;
        }
    }
    return true;
}

int main(void) {
    AudioObjectPropertyAddress devicesAddress = MakeAddress(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    );
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kSystemObject,
        &devicesAddress,
        0,
        NULL,
        &size
    );
    if (status != noErr) {
        fprintf(stderr, "audio-device-probe: failed to read device list size: ");
        PrintStatus(status);
        fputc('\n', stderr);
        return EXIT_FAILURE;
    }

    size_t deviceCount = size / sizeof(AudioDeviceID);
    if (deviceCount == 0) {
        puts("CoreAudio reported no devices in this login session.");
        return EXIT_SUCCESS;
    }

    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) {
        fputs("audio-device-probe: unable to allocate the device list\n", stderr);
        return EXIT_FAILURE;
    }
    status = AudioObjectGetPropertyData(
        kSystemObject,
        &devicesAddress,
        0,
        NULL,
        &size,
        devices
    );
    if (status != noErr) {
        fprintf(stderr, "audio-device-probe: failed to read device list: ");
        PrintStatus(status);
        fputc('\n', stderr);
        free(devices);
        return EXIT_FAILURE;
    }
    deviceCount = size / sizeof(AudioDeviceID);

    AudioDeviceID defaultOutput = kAudioObjectUnknown;
    AudioDeviceID defaultSystemOutput = kAudioObjectUnknown;
    ReadUInt32(
        kSystemObject,
        MakeAddress(kAudioHardwarePropertyDefaultOutputDevice,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain),
        &defaultOutput
    );
    ReadUInt32(
        kSystemObject,
        MakeAddress(kAudioHardwarePropertyDefaultSystemOutputDevice,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain),
        &defaultSystemOutput
    );

    puts("SoundVolumeControl read-only CoreAudio capability probe");
    printf("Devices: %zu\n", deviceCount);

    for (size_t index = 0; index < deviceCount; ++index) {
        AudioDeviceID deviceID = devices[index];
        int outputChannels = ChannelCount(deviceID, kAudioObjectPropertyScopeOutput);
        if (outputChannels <= 0) {
            continue;
        }

        int inputChannels = ChannelCount(deviceID, kAudioObjectPropertyScopeInput);
        char name[1024] = "Unnamed device";
        char uid[1024] = "unknown";
        ReadString(deviceID,
                   MakeAddress(kAudioObjectPropertyName,
                               kAudioObjectPropertyScopeGlobal,
                               kAudioObjectPropertyElementMain),
                   name,
                   (CFIndex)sizeof(name));
        ReadString(deviceID,
                   MakeAddress(kAudioDevicePropertyDeviceUID,
                               kAudioObjectPropertyScopeGlobal,
                               kAudioObjectPropertyElementMain),
                   uid,
                   (CFIndex)sizeof(uid));

        UInt32 transport = 0;
        UInt32 hiddenValue = 0;
        UInt32 aliveValue = 0;
        UInt32 canDefaultValue = 0;
        bool knowsHidden = ReadUInt32(
            deviceID,
            MakeAddress(kAudioDevicePropertyIsHidden,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain),
            &hiddenValue
        );
        bool knowsAlive = ReadUInt32(
            deviceID,
            MakeAddress(kAudioDevicePropertyDeviceIsAlive,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain),
            &aliveValue
        );
        bool knowsCanDefault = ReadUInt32(
            deviceID,
            MakeAddress(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                        kAudioObjectPropertyScopeOutput,
                        kAudioObjectPropertyElementMain),
            &canDefaultValue
        );
        ReadUInt32(
            deviceID,
            MakeAddress(kAudioDevicePropertyTransportType,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain),
            &transport
        );

        printf("\n%s", name);
        if (deviceID == defaultOutput || deviceID == defaultSystemOutput) {
            printf(" [");
            if (deviceID == defaultOutput) {
                printf("default output");
            }
            if (deviceID == defaultOutput && deviceID == defaultSystemOutput) {
                printf(", ");
            }
            if (deviceID == defaultSystemOutput) {
                printf("system sounds");
            }
            printf("]");
        }
        putchar('\n');

        char transportCode[5];
        FourCC(transport, transportCode);
        printf("  object ID: %u\n", deviceID);
        printf("  UID: %s\n", uid);
        printf("  transport: %s (0x%08x)\n", transportCode, transport);
        printf("  channels: %d output, %d input\n", outputChannels, inputChannels);
        printf("  alive / hidden / can default: %s / %s / %s\n",
               YesNoKnown(knowsAlive, aliveValue != 0),
               YesNoKnown(knowsHidden, hiddenValue != 0),
               YesNoKnown(knowsCanDefault, canDefaultValue != 0));

        printf("  volume output/main: ");
        PrintScalar(deviceID, kAudioObjectPropertyElementMain);
        putchar('\n');

        int reportedChannels = outputChannels < 2 ? outputChannels : 2;
        for (int channel = 1; channel <= reportedChannels; ++channel) {
            printf("  volume output/channel %d: ", channel);
            PrintScalar(deviceID, (AudioObjectPropertyElement)channel);
            putchar('\n');
        }

        AudioObjectPropertyAddress decibelsAddress = MakeAddress(
            kAudioDevicePropertyVolumeDecibels,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        );
        printf("  decibels output/main: ");
        if (!HasProperty(deviceID, decibelsAddress)) {
            printf("absent\n");
        } else {
            Float32 decibels = 0;
            bool settable = false;
            bool knowsSettable = IsSettable(deviceID, decibelsAddress, &settable);
            if (ReadFloat32(deviceID, decibelsAddress, &decibels)) {
                printf("%.3f dB", decibels);
            } else {
                printf("unreadable");
            }
            printf(" (writable: %s)\n", YesNoKnown(knowsSettable, settable));
        }

        printf("  mute output/main: ");
        PrintMute(deviceID);
        putchar('\n');
        printf("  volume conversion: ");
        PrintVolumeConversions(deviceID);
        putchar('\n');
        printf("  writable-volume candidate: %s\n",
               NativeVolumeCandidate(deviceID, outputChannels) ? "yes" : "no");
    }

    puts("\nNote: 'candidate' is a property-level heuristic. Native HUD, keyboard, and");
    puts("Control Center behavior still require the manual Phase 2 validation gate.");

    free(devices);
    return EXIT_SUCCESS;
}
