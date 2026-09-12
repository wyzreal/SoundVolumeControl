#import <CoreAudio/AudioHardware.h>
#import <Foundation/Foundation.h>

#include "AudioProcessor.h"
#include "SharedAudio.h"
#include "SecureAudio.h"
#include "StartupTiming.h"
#include "SharedAudioReader.h"
#include "SoundVolumeControlIDs.h"
#include "VolumeCurve.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <dispatch/dispatch.h>

#define SVC_FORWARDER_BUNDLE_ID "org.soundvolumecontrol.forwarder"

typedef struct {
    AudioDeviceID virtualDevice;
    AudioDeviceID physicalDevice;
    AudioDeviceIOProcID physicalIOProcID;
    AudioDeviceIOProcID virtualIOProcID;
    const SVCSharedAudio *sharedAudio;
    SVCReaderConnection *secureReader;
    SVCSharedAudioReader sharedAudioReader;
    Float32 *stereoScratch;
    UInt32 scratchCapacityFrames;
    bool volumeListenerInstalled;
    bool muteListenerInstalled;
    bool defaultListenerInstalled;
    SVCGainProcessor gainProcessor;
    bool diagnostics;
    _Atomic(UInt64) callbackCount;
    _Atomic(UInt64) forwardedFrameCount;
    _Atomic(UInt64) nonSilentCallbackCount;
} SVCForwarderContext;

typedef struct {
    _Atomic(bool) toneEnabled;
    Float64 phase;
    Float64 phaseIncrement;
} SVCWakeContext;

static volatile sig_atomic_t gShouldStop = 0;
static dispatch_semaphore_t gStateSemaphore;

static void HandleSignal(int signalNumber) {
    (void)signalNumber;
    gShouldStop = 1;
}

static OSStatus DefaultOutputChanged(AudioObjectID objectID,
                                     UInt32 numberAddresses,
                                     const AudioObjectPropertyAddress addresses[],
                                     void *clientData) {
    (void)objectID;
    (void)numberAddresses;
    (void)addresses;
    (void)clientData;
    if (gStateSemaphore != nil) {
        dispatch_semaphore_signal(gStateSemaphore);
    }
    return noErr;
}

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector,
                                          AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress) {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
}

static void FourCC(OSStatus status, char result[5]) {
    UInt32 raw = (UInt32)status;
    result[0] = (char)((raw >> 24) & 0xff);
    result[1] = (char)((raw >> 16) & 0xff);
    result[2] = (char)((raw >> 8) & 0xff);
    result[3] = (char)(raw & 0xff);
    result[4] = '\0';
    for (size_t index = 0; index < 4; ++index) {
        if (result[index] < 32 || result[index] > 126) {
            result[index] = '?';
        }
    }
}

static void ReportStatus(const char *operation, OSStatus status) {
    char code[5];
    FourCC(status, code);
    fprintf(stderr, "%s failed: %d ('%s')\n", operation, status, code);
}

// A full-duplex device must not start its input streams for this output-only app.
static OSStatus DisableInputStreams(AudioDeviceID device,
                                    AudioDeviceIOProcID ioProc) {
    AudioObjectPropertyAddress streams = Address(
        kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput
    );
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &streams,
                                                    0, NULL, &size);
    if (status != noErr || size == 0) {
        return status;
    }
    UInt32 count = size / sizeof(AudioStreamID);
    size_t usageSize = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn)
        + count * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, usageSize);
    if (usage == NULL) {
        return kAudioHardwareUnspecifiedError;
    }
    _Static_assert(sizeof(usage->mIOProc) == sizeof(ioProc), "IOProc pointer size");
    memcpy(&usage->mIOProc, &ioProc, sizeof(ioProc));
    usage->mNumberStreams = count;
    AudioObjectPropertyAddress address = Address(
        kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput
    );
    status = AudioObjectSetPropertyData(device, &address, 0, NULL,
                                        (UInt32)usageSize, usage);
    free(usage);
    return status;
}

static bool ReadUInt32(AudioObjectID objectID,
                       AudioObjectPropertyAddress address,
                       UInt32 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address,
                                      0, NULL, &size, value) == noErr;
}

static bool ReadFloat32(AudioObjectID objectID,
                        AudioObjectPropertyAddress address,
                        Float32 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address,
                                      0, NULL, &size, value) == noErr;
}

static bool ReadFloat64(AudioObjectID objectID,
                        AudioObjectPropertyAddress address,
                        Float64 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address,
                                      0, NULL, &size, value) == noErr;
}

static CFStringRef CopyStringProperty(AudioObjectID objectID,
                                      AudioObjectPropertyAddress address) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(objectID, &address, 0, NULL,
                                   &size, &value) != noErr) {
        return NULL;
    }
    return value;
}

static AudioDeviceID FindDeviceByUID(CFStringRef uid) {
    if (uid == NULL) {
        return kAudioObjectUnknown;
    }
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = Address(
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal
    );
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                   sizeof(uid), &uid,
                                   &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static int ChannelCount(AudioDeviceID device,
                        AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = Address(
        kAudioDevicePropertyStreamConfiguration, scope
    );
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr
        || size < sizeof(UInt32)) {
        return 0;
    }
    AudioBufferList *list = malloc(size);
    if (list == NULL) {
        return 0;
    }
    if (AudioObjectGetPropertyData(device, &address, 0, NULL,
                                   &size, list) != noErr) {
        free(list);
        return 0;
    }
    int count = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        count += (int)list->mBuffers[index].mNumberChannels;
    }
    free(list);
    return count;
}

static bool IsPhysicalOutput(AudioDeviceID device,
                             AudioDeviceID virtualDevice) {
    if (device == kAudioObjectUnknown || device == virtualDevice
        || ChannelCount(device, kAudioObjectPropertyScopeOutput) <= 0) {
        return false;
    }
    UInt32 transport = kAudioDeviceTransportTypeUnknown;
    if (!ReadUInt32(device,
                    Address(kAudioDevicePropertyTransportType,
                            kAudioObjectPropertyScopeGlobal),
                    &transport)) {
        return false;
    }
    return transport != kAudioDeviceTransportTypeVirtual
        && transport != kAudioDeviceTransportTypeAggregate;
}

static int TransportPriority(UInt32 transport) {
    switch (transport) {
        case kAudioDeviceTransportTypeHDMI:
        case kAudioDeviceTransportTypeDisplayPort:
            return 100;
        case kAudioDeviceTransportTypeUSB:
        case kAudioDeviceTransportTypeThunderbolt:
            return 90;
        case kAudioDeviceTransportTypeBuiltIn:
            return 60;
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE:
            return 40;
        case kAudioDeviceTransportTypeAirPlay:
            return 30;
        default:
            return 10;
    }
}

static AudioDeviceID BestAvailablePhysicalOutput(AudioDeviceID virtualDevice) {
    AudioObjectPropertyAddress address = Address(
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal
    );
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address,
                                       0, NULL, &size) != noErr
        || size == 0) {
        return kAudioObjectUnknown;
    }
    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) {
        return kAudioObjectUnknown;
    }
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                   0, NULL, &size, devices) != noErr) {
        free(devices);
        return kAudioObjectUnknown;
    }

    AudioDeviceID best = kAudioObjectUnknown;
    int bestPriority = -1;
    size_t count = size / sizeof(AudioDeviceID);
    for (size_t index = 0; index < count; ++index) {
        AudioDeviceID candidate = devices[index];
        if (!IsPhysicalOutput(candidate, virtualDevice)) {
            continue;
        }
        UInt32 transport = 0;
        (void)ReadUInt32(candidate,
                         Address(kAudioDevicePropertyTransportType,
                                 kAudioObjectPropertyScopeGlobal),
                         &transport);
        int priority = TransportPriority(transport);
        if (priority > bestPriority) {
            best = candidate;
            bestPriority = priority;
        }
    }
    free(devices);
    return best;
}

static void PersistPhysicalUID(CFStringRef uid) {
    if (uid == NULL) {
        return;
    }
    CFPreferencesSetAppValue(CFSTR("physicalDeviceUID"), uid,
                             CFSTR(SVC_FORWARDER_BUNDLE_ID));
    (void)CFPreferencesAppSynchronize(CFSTR(SVC_FORWARDER_BUNDLE_ID));
}

static AudioDeviceID SelectPhysicalOutput(AudioDeviceID virtualDevice,
                                          NSString *explicitUID) {
    if (explicitUID != nil) {
        AudioDeviceID device = FindDeviceByUID((__bridge CFStringRef)explicitUID);
        return IsPhysicalOutput(device, virtualDevice)
            ? device : kAudioObjectUnknown;
    }

    AudioDeviceID currentDefault = kAudioObjectUnknown;
    (void)ReadUInt32(kAudioObjectSystemObject,
                     Address(kAudioHardwarePropertyDefaultOutputDevice,
                             kAudioObjectPropertyScopeGlobal),
                     &currentDefault);
    if (IsPhysicalOutput(currentDefault, virtualDevice)) {
        return currentDefault;
    }

    CFPropertyListRef saved = CFPreferencesCopyAppValue(
        CFSTR("physicalDeviceUID"), CFSTR(SVC_FORWARDER_BUNDLE_ID)
    );
    AudioDeviceID savedDevice = kAudioObjectUnknown;
    if (saved != NULL && CFGetTypeID(saved) == CFStringGetTypeID()) {
        savedDevice = FindDeviceByUID((CFStringRef)saved);
    }
    if (saved != NULL) {
        CFRelease(saved);
    }
    if (IsPhysicalOutput(savedDevice, virtualDevice)) {
        return savedDevice;
    }
    return BestAvailablePhysicalOutput(virtualDevice);
}

static AudioDeviceID DefaultOutput(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    (void)ReadUInt32(kAudioObjectSystemObject,
                     Address(kAudioHardwarePropertyDefaultOutputDevice,
                             kAudioObjectPropertyScopeGlobal),
                     &device);
    return device;
}

static Float32 SoftwareGain(AudioDeviceID virtualDevice) {
    Float32 scalar = 1.0f;
    UInt32 mute = 0;
    (void)ReadFloat32(virtualDevice,
                      Address(kAudioDevicePropertyVolumeScalar,
                              kAudioObjectPropertyScopeOutput),
                      &scalar);
    (void)ReadUInt32(virtualDevice,
                     Address(kAudioDevicePropertyMute,
                             kAudioObjectPropertyScopeOutput),
                     &mute);
    if (mute != 0) {
        return 0.0f;
    }
    return SVCVolumeScalarToGain(scalar);
}

static OSStatus ControlChanged(AudioObjectID objectID,
                               UInt32 numberAddresses,
                               const AudioObjectPropertyAddress addresses[],
                               void *clientData) {
    (void)objectID;
    (void)numberAddresses;
    (void)addresses;
    SVCForwarderContext *context = clientData;
    SVCGainProcessorSetTarget(&context->gainProcessor,
                              SoftwareGain(context->virtualDevice));
    return noErr;
}

static UInt32 MaximumFrames(const AudioBufferList *list) {
    UInt32 maximum = 0;
    if (list == NULL) {
        return maximum;
    }
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &list->mBuffers[index];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
            continue;
        }
        UInt32 frames = buffer->mDataByteSize
            / (sizeof(Float32) * buffer->mNumberChannels);
        if (frames > maximum) {
            maximum = frames;
        }
    }
    return maximum;
}

static SVCReaderConnection *MapDriverAudio(void) {
    char *requirement = SVCCopyBrokerRequirement(CFSTR(SVC_FORWARDER_BUNDLE_ID));
    if (requirement == NULL) { errno = EACCES; return NULL; }
    SVCReaderConnection *reader = SVCReaderOpen(SVC_BROKER_READER, requirement, true, SVC_BUFFER_STARTUP_SECONDS);
    free(requirement);
    return reader;
}

static bool ContainsNonSilentFloat(const AudioBufferList *list) {
    if (list == NULL) {
        return false;
    }
    for (UInt32 bufferIndex = 0;
         bufferIndex < list->mNumberBuffers;
         ++bufferIndex) {
        const AudioBuffer *buffer = &list->mBuffers[bufferIndex];
        if (buffer->mData == NULL) {
            continue;
        }
        const Float32 *samples = buffer->mData;
        UInt32 count = buffer->mDataByteSize / sizeof(Float32);
        for (UInt32 index = 0; index < count; ++index) {
            if (fabsf(samples[index]) > 0.000001f) {
                return true;
            }
        }
    }
    return false;
}

static OSStatus ForwardIO(AudioDeviceID inDevice,
                          const AudioTimeStamp *inNow,
                          const AudioBufferList *inInputData,
                          const AudioTimeStamp *inInputTime,
                          AudioBufferList *outOutputData,
                          const AudioTimeStamp *inOutputTime,
                          void *inClientData) {
    (void)inDevice;
    (void)inNow;
    (void)inInputData;
    (void)inInputTime;
    (void)inOutputTime;
    SVCForwarderContext *context = inClientData;
    atomic_fetch_add_explicit(&context->callbackCount, 1, memory_order_relaxed);

    UInt32 frames = MaximumFrames(outOutputData);
    if (frames > context->scratchCapacityFrames) {
        frames = context->scratchCapacityFrames;
    }
    UInt32 rendered = SVCSharedAudioReaderRead(
        &context->sharedAudioReader, context->stereoScratch, frames
    );
    AudioBufferList input = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = kSVCSharedAudioChannelCount,
            .mDataByteSize = frames * kSVCSharedAudioChannelCount
                * sizeof(Float32),
            .mData = context->stereoScratch,
        }},
    };
    atomic_fetch_add_explicit(&context->forwardedFrameCount,
                              rendered,
                              memory_order_relaxed);
    if (context->diagnostics && ContainsNonSilentFloat(&input)) {
        atomic_fetch_add_explicit(&context->nonSilentCallbackCount,
                                  1, memory_order_relaxed);
    }
    SVCGainProcessorProcess(&context->gainProcessor, &input, outOutputData);
    return noErr;
}

static OSStatus WakeVirtualIO(AudioDeviceID inDevice,
                              const AudioTimeStamp *inNow,
                              const AudioBufferList *inInputData,
                              const AudioTimeStamp *inInputTime,
                              AudioBufferList *outOutputData,
                              const AudioTimeStamp *inOutputTime,
                              void *inClientData) {
    (void)inDevice;
    (void)inNow;
    (void)inInputData;
    (void)inInputTime;
    (void)inOutputTime;
    SVCWakeContext *wake = inClientData;
    if (outOutputData == NULL) {
        return noErr;
    }
    for (UInt32 index = 0; index < outOutputData->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &outOutputData->mBuffers[index];
        if (buffer->mData == NULL || buffer->mDataByteSize == 0) {
            continue;
        }
        if (wake == NULL
            || !atomic_load_explicit(&wake->toneEnabled,
                                     memory_order_relaxed)) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
            continue;
        }
        Float32 *samples = buffer->mData;
        UInt32 sampleCount = buffer->mDataByteSize / sizeof(Float32);
        UInt32 channels = buffer->mNumberChannels == 0
            ? 1 : buffer->mNumberChannels;
        for (UInt32 sampleIndex = 0;
             sampleIndex < sampleCount;
             sampleIndex += channels) {
            Float32 sample = 0.25f * (Float32)sin(wake->phase);
            wake->phase += wake->phaseIncrement;
            if (wake->phase >= 2.0 * M_PI) {
                wake->phase -= 2.0 * M_PI;
            }
            UInt32 frameEnd = sampleIndex + channels;
            if (frameEnd > sampleCount) {
                frameEnd = sampleCount;
            }
            for (UInt32 channelSample = sampleIndex;
                 channelSample < frameEnd;
                 ++channelSample) {
                samples[channelSample] = sample;
            }
        }
    }
    return noErr;
}

static void Cleanup(SVCForwarderContext *context) {
    AudioObjectPropertyAddress volume = Address(
        kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput
    );
    AudioObjectPropertyAddress mute = Address(
        kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput
    );
    if (context->physicalIOProcID != NULL) {
        (void)AudioDeviceStop(context->physicalDevice,
                              context->physicalIOProcID);
        (void)AudioDeviceDestroyIOProcID(context->physicalDevice,
                                         context->physicalIOProcID);
        context->physicalIOProcID = NULL;
    }
    if (context->virtualIOProcID != NULL) {
        (void)AudioDeviceStop(context->virtualDevice,
                              context->virtualIOProcID);
        (void)AudioDeviceDestroyIOProcID(context->virtualDevice,
                                         context->virtualIOProcID);
        context->virtualIOProcID = NULL;
    }
    if (context->volumeListenerInstalled) {
        (void)AudioObjectRemovePropertyListener(context->virtualDevice,
                                                &volume,
                                                ControlChanged,
                                                context);
        context->volumeListenerInstalled = false;
    }
    if (context->muteListenerInstalled) {
        (void)AudioObjectRemovePropertyListener(context->virtualDevice,
                                                &mute,
                                                ControlChanged,
                                                context);
        context->muteListenerInstalled = false;
    }
    free(context->stereoScratch);
    context->stereoScratch = NULL;
    context->scratchCapacityFrames = 0;
    if (context->secureReader != NULL) {
        SVCReaderClose(context->secureReader);
        context->secureReader = NULL;
        context->sharedAudio = NULL;
    }
    if (context->defaultListenerInstalled) {
        AudioObjectPropertyAddress defaultOutput = Address(
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal
        );
        (void)AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                                &defaultOutput,
                                                DefaultOutputChanged,
                                                context);
        context->defaultListenerInstalled = false;
    }
}

static void PrintUsage(const char *program) {
    fprintf(stderr,
            "usage: %s [--physical-uid UID] [--run-seconds N] "
            "[--diagnose] [--always-active] [--test-tone] "
            "[--remove-shared-audio]\n",
            program);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *explicitPhysicalUID = nil;
        UInt32 runSeconds = 0;
        bool diagnostics = false;
        bool alwaysActive = false;
        bool testTone = false;
        bool removeSharedAudio = false;
        for (int index = 1; index < argc; ++index) {
            if (strcmp(argv[index], "--physical-uid") == 0
                && index + 1 < argc) {
                explicitPhysicalUID = [NSString stringWithUTF8String:argv[++index]];
            } else if (strcmp(argv[index], "--run-seconds") == 0
                       && index + 1 < argc) {
                char *end = NULL;
                unsigned long value = strtoul(argv[++index], &end, 10);
                if (end == NULL || *end != '\0' || value == 0 || value > 3600) {
                    PrintUsage(argv[0]);
                    return 64;
                }
                runSeconds = (UInt32)value;
            } else if (strcmp(argv[index], "--diagnose") == 0) {
                diagnostics = true;
            } else if (strcmp(argv[index], "--always-active") == 0) {
                alwaysActive = true;
            } else if (strcmp(argv[index], "--test-tone") == 0) {
                testTone = true;
            } else if (strcmp(argv[index], "--remove-shared-audio") == 0) {
                removeSharedAudio = true;
            } else {
                PrintUsage(argv[0]);
                return 64;
            }
        }

        if (removeSharedAudio) {
            const char *names[] = {
                SVC_SHARED_AUDIO_NAME, SVC_LEGACY_SHARED_AUDIO_NAME,
            };
            for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); ++index) {
                if (shm_unlink(names[index]) != 0 && errno != ENOENT) {
                    perror("shm_unlink");
                    return EXIT_FAILURE;
                }
            }
            return EXIT_SUCCESS;
        }

        SVCForwarderContext context = {
            .virtualDevice = kAudioObjectUnknown,
            .physicalDevice = kAudioObjectUnknown,
            .physicalIOProcID = NULL,
            .virtualIOProcID = NULL,
            .diagnostics = diagnostics,
        };
        atomic_init(&context.callbackCount, 0);
        atomic_init(&context.forwardedFrameCount, 0);
        atomic_init(&context.nonSilentCallbackCount, 0);
        gStateSemaphore = dispatch_semaphore_create(0);
        signal(SIGINT, HandleSignal);
        signal(SIGTERM, HandleSignal);

        context.virtualDevice = FindDeviceByUID(CFSTR(SVC_DEVICE_UID));
        if (context.virtualDevice == kAudioObjectUnknown) {
            fputs("Sound Volume is not installed or registered with CoreAudio.\n",
                  stderr);
            return EXIT_FAILURE;
        }

        AudioObjectPropertyAddress defaultOutputAddress = Address(
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal
        );
        OSStatus status = AudioObjectAddPropertyListener(
            kAudioObjectSystemObject, &defaultOutputAddress,
            DefaultOutputChanged, &context
        );
        if (status != noErr) {
            ReportStatus("default-output listener", status);
            return EXIT_FAILURE;
        }
        context.defaultListenerInstalled = true;

        context.physicalDevice = SelectPhysicalOutput(context.virtualDevice,
                                                      explicitPhysicalUID);
        if (context.physicalDevice == kAudioObjectUnknown) {
            fputs("No eligible physical output is available.\n", stderr);
            Cleanup(&context);
            return EXIT_FAILURE;
        }

        CFStringRef physicalUIDRef = CopyStringProperty(
            context.physicalDevice,
            Address(kAudioDevicePropertyDeviceUID,
                    kAudioObjectPropertyScopeGlobal)
        );
        CFStringRef physicalNameRef = CopyStringProperty(
            context.physicalDevice,
            Address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        );
        if (physicalUIDRef == NULL) {
            fputs("The selected physical output has no readable UID.\n", stderr);
            if (physicalNameRef != NULL) {
                CFRelease(physicalNameRef);
            }
            return EXIT_FAILURE;
        }
        NSString *physicalUID = (__bridge NSString *)physicalUIDRef;
        NSString *physicalName = physicalNameRef == NULL
            ? @"Unnamed output" : (__bridge NSString *)physicalNameRef;
        PersistPhysicalUID(physicalUIDRef);
        printf("Physical output: %s (%s)\n",
               physicalName.UTF8String, physicalUID.UTF8String);

        Float64 virtualRate = 0;
        Float64 physicalRate = 0;
        (void)ReadFloat64(context.virtualDevice,
                          Address(kAudioDevicePropertyNominalSampleRate,
                                  kAudioObjectPropertyScopeGlobal),
                          &virtualRate);
        (void)ReadFloat64(context.physicalDevice,
                          Address(kAudioDevicePropertyNominalSampleRate,
                                  kAudioObjectPropertyScopeGlobal),
                          &physicalRate);
        if (virtualRate != physicalRate || virtualRate <= 0) {
            fprintf(stderr,
                    "Sample-rate mismatch: Sound Volume %.0f Hz, physical %.0f Hz.\n",
                    virtualRate, physicalRate);
            CFRelease(physicalUIDRef);
            if (physicalNameRef != NULL) {
                CFRelease(physicalNameRef);
            }
            return EXIT_FAILURE;
        }

        context.secureReader = MapDriverAudio();
        context.sharedAudio = context.secureReader == NULL ? NULL : SVCReaderAudio(context.secureReader);
        if (context.sharedAudio == NULL) {
            int error = errno;
            const char *detail = error == EACCES
                ? "Authentication rejected. Install the matching app, driver, and broker together."
                : error == EBUSY ? "Another audio helper is connected. Quit other copies of SoundVolumeControl."
                : error == ETIMEDOUT ? "The audio service did not provide a buffer within 20 seconds. Try Enable again."
                : error == ECONNRESET ? "The audio service disconnected during startup. Try Enable again."
                : "Invalid audio buffer response. Install the matching components together.";
            fprintf(stderr, "Driver buffer failed: %s (%d). %s\n", strerror(error), error, detail);
            Cleanup(&context);
            CFRelease(physicalUIDRef);
            if (physicalNameRef != NULL) {
                CFRelease(physicalNameRef);
            }
            return EXIT_FAILURE;
        }
        context.scratchCapacityFrames = kSVCSharedAudioCapacityFrames;
        context.stereoScratch = calloc(
            (size_t)context.scratchCapacityFrames,
            kSVCSharedAudioChannelCount * sizeof(Float32)
        );
        if (context.stereoScratch == NULL) {
            fputs("Unable to allocate the forwarding buffer.\n", stderr);
            Cleanup(&context);
            CFRelease(physicalUIDRef);
            if (physicalNameRef != NULL) {
                CFRelease(physicalNameRef);
            }
            return EXIT_FAILURE;
        }
        UInt32 physicalBufferFrames = 512;
        (void)ReadUInt32(
            context.physicalDevice,
            Address(kAudioDevicePropertyBufferFrameSize,
                    kAudioObjectPropertyScopeGlobal),
            &physicalBufferFrames
        );
        UInt32 targetLatencyFrames = physicalBufferFrames * 4;
        if (targetLatencyFrames < 1024) {
            targetLatencyFrames = 1024;
        }
        SVCSharedAudioReaderInit(&context.sharedAudioReader,
                                 context.sharedAudio,
                                 targetLatencyFrames);
        printf("Driver buffer: output capture, %u-frame target latency\n",
               context.sharedAudioReader.targetLatencyFrames);

        Float32 initialGain = SoftwareGain(context.virtualDevice);
        SVCGainProcessorInit(&context.gainProcessor, initialGain,
                             virtualRate, 5.0);
        printf("Initial software gain: %.6f\n", initialGain);

        AudioObjectPropertyAddress volume = Address(
            kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput
        );
        AudioObjectPropertyAddress mute = Address(
            kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput
        );
        status = AudioObjectAddPropertyListener(
            context.virtualDevice, &volume, ControlChanged, &context
        );
        if (status == noErr) {
            context.volumeListenerInstalled = true;
            status = AudioObjectAddPropertyListener(
                context.virtualDevice, &mute, ControlChanged, &context
            );
            if (status == noErr) {
                context.muteListenerInstalled = true;
            }
        }
        if (status != noErr) {
            ReportStatus("AudioObjectAddPropertyListener", status);
            Cleanup(&context);
            CFRelease(physicalUIDRef);
            if (physicalNameRef != NULL) {
                CFRelease(physicalNameRef);
            }
            return EXIT_FAILURE;
        }
        status = AudioDeviceCreateIOProcID(context.physicalDevice,
                                           ForwardIO, &context,
                                           &context.physicalIOProcID);
        if (status == noErr) {
            status = DisableInputStreams(context.physicalDevice,
                                          context.physicalIOProcID);
        }
        SVCWakeContext wakeContext = {
            .phase = 0.0,
            .phaseIncrement = 2.0 * M_PI * 440.0 / virtualRate,
        };
        atomic_init(&wakeContext.toneEnabled, false);
        if (status == noErr && testTone) {
            status = AudioDeviceCreateIOProcID(context.virtualDevice,
                                               WakeVirtualIO, &wakeContext,
                                               &context.virtualIOProcID);
        }
        if (status == noErr) {
            status = AudioDeviceStart(context.physicalDevice,
                                      context.physicalIOProcID);
        }
        if (status == noErr && testTone) {
            atomic_store_explicit(&wakeContext.toneEnabled, true,
                                  memory_order_relaxed);
            status = AudioDeviceStart(context.virtualDevice,
                                      context.virtualIOProcID);
        }
        if (status == noErr && testTone) {
            const struct timespec toneDuration = {
                .tv_sec = 1,
                .tv_nsec = 0,
            };
            (void)nanosleep(&toneDuration, NULL);
            atomic_store_explicit(&wakeContext.toneEnabled, false,
                                  memory_order_relaxed);
        }
        if (status != noErr) {
            ReportStatus("starting output forwarding IO", status);
            Cleanup(&context);
            CFRelease(physicalUIDRef);
            if (physicalNameRef != NULL) {
                CFRelease(physicalNameRef);
            }
            return EXIT_FAILURE;
        }

        time_t endTime = runSeconds == 0 ? 0 : time(NULL) + (time_t)runSeconds;
        puts("Forwarder ready.");
        fflush(stdout);
        if (!alwaysActive && DefaultOutput() != context.virtualDevice) {
            puts("Waiting for Sound Volume to become the macOS output.");
            fflush(stdout);
            while (!gShouldStop && (endTime == 0 || time(NULL) < endTime)
                   && SVCReaderIsAlive(context.secureReader)
                   && DefaultOutput() != context.virtualDevice) {
                (void)dispatch_semaphore_wait(
                    gStateSemaphore,
                    dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)
                );
            }
        }
        if (!gShouldStop && (endTime == 0 || time(NULL) < endTime)
            && SVCReaderIsAlive(context.secureReader)) {
            puts("Forwarding is active.");
        }
        fflush(stdout);
        while (!gShouldStop && (endTime == 0 || time(NULL) < endTime)) {
            if (!SVCReaderIsAlive(context.secureReader)) {
                fputs("Audio broker failed: connection revoked or stopped.\n", stderr);
                break;
            }
            if (!alwaysActive && DefaultOutput() != context.virtualDevice) {
                puts("Sound Volume is no longer selected; stopping physical IO.");
                break;
            }
            (void)dispatch_semaphore_wait(
                gStateSemaphore,
                dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)
            );
        }

        if (diagnostics && context.sharedAudio != NULL) {
            printf("Driver callbacks: %u ProcessOutput, %u WriteMix; write frame %llu\n",
                   atomic_load(&context.sharedAudio->processOutputCount),
                   atomic_load(&context.sharedAudio->writeMixCount),
                   (unsigned long long)atomic_load(&context.sharedAudio->writeFrame));
        }
        Cleanup(&context);
        UInt64 callbacks = atomic_load_explicit(&context.callbackCount,
                                                memory_order_relaxed);
        UInt64 frames = atomic_load_explicit(&context.forwardedFrameCount,
                                             memory_order_relaxed);
        UInt64 nonSilent = atomic_load_explicit(&context.nonSilentCallbackCount,
                                                memory_order_relaxed);
        printf("Stopped: %llu callbacks, %llu forwarded frames",
               callbacks, frames);
        if (diagnostics) {
            printf(", %llu non-silent callbacks, %llu underruns, "
                   "%llu resynchronizations",
                   nonSilent,
                   context.sharedAudioReader.underrunCount,
                   context.sharedAudioReader.resyncCount);
        }
        putchar('\n');

        CFRelease(physicalUIDRef);
        if (physicalNameRef != NULL) {
            CFRelease(physicalNameRef);
        }
        return EXIT_SUCCESS;
    }
}
