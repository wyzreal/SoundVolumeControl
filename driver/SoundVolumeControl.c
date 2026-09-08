#include "SoundVolumeControlIDs.h"
#include "SharedAudio.h"
#ifdef SVC_IPC_TESTING
#include "SharedAudioTransport.h"
#endif
#include "SecureAudio.h"
#include "VolumeCurve.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <math.h>
#include <errno.h>
#include <os/log.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define SVC_UNUSED(value) ((void)(value))

static AudioServerPlugInDriverInterface gDriverInterface;
static AudioServerPlugInDriverInterface *gDriverInterfacePointer = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePointer;

static _Atomic(UInt32) gReferenceCount = 1;
static _Atomic(UInt32) gRunningCount = 0;
static _Atomic(UInt64) gTimestampAnchor = 0;
static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static Float32 gVolumeScalar = 1.0f;
static UInt32 gMute = 0;
static UInt32 gOutputStreamActive = 1;
static Float64 gHostTicksPerFrame = 0.0;
#if defined(SVC_TESTING) || defined(SVC_IPC_TESTING)
static SVCSharedAudio *gSharedAudio = NULL;
static SVCSharedAudio *AcquireAudio(void) { return gSharedAudio; }
static void ReleaseAudio(void) {}
#else
static SVCSharedAudio *AcquireAudio(void) { return SVCWriterAcquire(); }
static void ReleaseAudio(void) { SVCWriterRelease(); }
#endif

#ifdef SVC_TESTING
static SVCSharedAudio gTestSharedAudio;

SVCSharedAudio *SVCDriverTestSharedAudio(void) {
    return &gTestSharedAudio;
}
#endif

static OSStatus InitializeSharedAudio(void) {
#if defined(SVC_TESTING) || defined(SVC_IPC_TESTING)
    if (gSharedAudio != NULL) return noErr;
#ifdef SVC_TESTING
    gSharedAudio = &gTestSharedAudio;
    SVCSharedAudioInitialize(gSharedAudio, kSVCSampleRate);
#else
    const char *sharedName = SVC_SHARED_AUDIO_NAME;
#ifdef SVC_IPC_TESTING
    extern const char *SVCDriverIPCName(void);
    sharedName = SVCDriverIPCName();
#endif
    gSharedAudio = SVCSharedAudioCreate(sharedName, 0600);
    if (gSharedAudio == NULL) {
        os_log_error(OS_LOG_DEFAULT,
                     "SoundVolumeControl shared buffer initialization failed: %{public}d",
                     errno);
        return kAudioHardwareUnspecifiedError;
    }
#endif
#else
#ifdef SVC_SECURE_IPC_TESTING
    extern const char *SVCTestBrokerName(void);
    extern const char *SVCTestBrokerRequirement(void);
    if (!SVCWriterConnect(SVCTestBrokerName(), SVCTestBrokerRequirement(), false))
        return kAudioHardwareUnspecifiedError;
#else
    char *requirement = SVCCopyBrokerRequirement(CFSTR("org.soundvolumecontrol.driver"));
    if (requirement == NULL) return kAudioHardwareUnspecifiedError;
    bool connected = SVCWriterConnect(SVC_BROKER_WRITER, requirement, true);
    free(requirement);
    if (!connected) return kAudioHardwareUnspecifiedError;
#endif
#endif
    return noErr;
}

static void ResetSharedAudioStream(void) {
    SVCSharedAudio *gSharedAudio = AcquireAudio();
    if (!SVCSharedAudioIsValid(gSharedAudio)) { ReleaseAudio(); return; }
    atomic_store_explicit(&gSharedAudio->writerActive, 0, memory_order_release);
    atomic_store_explicit(&gSharedAudio->streamEpoch, mach_absolute_time(),
                          memory_order_release);
    atomic_store(&gSharedAudio->writeFrame, 0);
    atomic_store(&gSharedAudio->streamStartFrame, 0);
    atomic_store(&gSharedAudio->processOutputCount, 0);
    atomic_store(&gSharedAudio->writeMixCount, 0);
    for (UInt32 index = 0; index < kSVCSharedAudioCapacityFrames; ++index) {
        atomic_store(&gSharedAudio->frames[index].tag, 0);
    }
    ReleaseAudio();
}

static void CaptureOutput(SVCSharedAudio *gSharedAudio, const Float32 *source,
                          Float64 rawSampleTime,
                          UInt32 frameCount) {
    if (source == NULL || !isfinite(rawSampleTime) || rawSampleTime < 0.0
        || rawSampleTime >= 0x1p53 || frameCount == 0
        || !SVCSharedAudioIsValid(gSharedAudio)) {
        return;
    }
    UInt64 sampleFrame = (UInt64)rawSampleTime;
    if (frameCount > kSVCSharedAudioCapacityFrames) {
        UInt32 skipped = frameCount - kSVCSharedAudioCapacityFrames;
        source += (size_t)skipped * kSVCChannelCount;
        sampleFrame += skipped;
        frameCount = kSVCSharedAudioCapacityFrames;
    }
    if (atomic_load(&gSharedAudio->writerActive) == 0) {
        atomic_store(&gSharedAudio->streamStartFrame, sampleFrame);
        atomic_store(&gSharedAudio->writeFrame, sampleFrame);
    }
    for (UInt32 frame = 0; frame < frameCount; ++frame) {
        SVCSharedAudioStoreFrame(gSharedAudio, sampleFrame + frame,
                                &source[(size_t)frame * kSVCChannelCount]);
    }
    atomic_store_explicit(&gSharedAudio->writeFrame, sampleFrame + frameCount,
                          memory_order_release);
    atomic_store_explicit(&gSharedAudio->writerActive, 1, memory_order_release);
}

static Boolean IsDriver(AudioServerPlugInDriverRef inDriver) {
    return inDriver == gDriverRef;
}

static Boolean IsKnownObject(AudioObjectID inObjectID) {
    return inObjectID >= kSVCObjectPlugin && inObjectID <= kSVCObjectLast;
}

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress) {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
}

static void Notify(AudioObjectID objectID,
                   UInt32 count,
                   const AudioObjectPropertyAddress *addresses) {
    AudioServerPlugInHostRef host = gHost;
    if (host != NULL && host->PropertiesChanged != NULL) {
        (void)host->PropertiesChanged(host, objectID, count, addresses);
    }
}

static AudioStreamBasicDescription StreamFormat(void) {
    return (AudioStreamBasicDescription) {
        .mSampleRate = kSVCSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagsNativeEndian
            | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = kSVCChannelCount * sizeof(Float32),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = kSVCChannelCount * sizeof(Float32),
        .mChannelsPerFrame = kSVCChannelCount,
        .mBitsPerChannel = 8 * sizeof(Float32),
        .mReserved = 0,
    };
}

static AudioClassID BaseClassForObject(AudioObjectID objectID) {
    switch (objectID) {
        case kSVCObjectVolume:
            return kAudioLevelControlClassID;
        case kSVCObjectMute:
            return kAudioBooleanControlClassID;
        default:
            return kAudioObjectClassID;
    }
}

static AudioClassID ClassForObject(AudioObjectID objectID) {
    switch (objectID) {
        case kSVCObjectPlugin:
            return kAudioPlugInClassID;
        case kSVCObjectDevice:
            return kAudioDeviceClassID;
        case kSVCObjectOutputStream:
            return kAudioStreamClassID;
        case kSVCObjectVolume:
            return kAudioVolumeControlClassID;
        case kSVCObjectMute:
            return kAudioMuteControlClassID;
        default:
            return kAudioObjectClassID;
    }
}

static AudioObjectID OwnerForObject(AudioObjectID objectID) {
    switch (objectID) {
        case kSVCObjectDevice:
            return kSVCObjectPlugin;
        case kSVCObjectOutputStream:
        case kSVCObjectVolume:
        case kSVCObjectMute:
            return kSVCObjectDevice;
        default:
            return kAudioObjectUnknown;
    }
}

static CFStringRef CopyNameForObject(AudioObjectID objectID) {
    switch (objectID) {
        case kSVCObjectPlugin:
            return CFRetain(CFSTR("SoundVolumeControl Driver"));
        case kSVCObjectDevice:
            return CFRetain(CFSTR(SVC_DEVICE_NAME));
        case kSVCObjectOutputStream:
            return CFRetain(CFSTR("Sound Volume Output"));
        case kSVCObjectVolume:
            return CFRetain(CFSTR("Sound Volume Master Volume"));
        case kSVCObjectMute:
            return CFRetain(CFSTR("Sound Volume Master Mute"));
        default:
            return NULL;
    }
}

static Boolean ObjectMatchesClass(AudioObjectID objectID,
                                  AudioClassID requestedClass) {
    if (requestedClass == kAudioObjectClassID
        || requestedClass == ClassForObject(objectID)) {
        return true;
    }
    if (objectID == kSVCObjectVolume) {
        return requestedClass == kAudioLevelControlClassID
            || requestedClass == kAudioControlClassID;
    }
    if (objectID == kSVCObjectMute) {
        return requestedClass == kAudioBooleanControlClassID
            || requestedClass == kAudioControlClassID;
    }
    return false;
}

static OSStatus FilteredOwnedObjects(AudioObjectID objectID,
                                     AudioObjectPropertyScope scope,
                                     UInt32 qualifierDataSize,
                                     const void *qualifierData,
                                     AudioObjectID output[4],
                                     UInt32 *outCount) {
    if (outCount == NULL
        || qualifierDataSize % sizeof(AudioClassID) != 0
        || (qualifierDataSize > 0 && qualifierData == NULL)) {
        return kAudioHardwareBadPropertySizeError;
    }
    AudioObjectID candidates[4] = {0};
    UInt32 candidateCount = 0;
    if (objectID == kSVCObjectPlugin) {
        candidates[candidateCount++] = kSVCObjectDevice;
    } else if (objectID == kSVCObjectDevice) {
        if (scope == kAudioObjectPropertyScopeGlobal
            || scope == kAudioObjectPropertyScopeOutput) {
            candidates[candidateCount++] = kSVCObjectOutputStream;
            candidates[candidateCount++] = kSVCObjectVolume;
            candidates[candidateCount++] = kSVCObjectMute;
        }
    }

    const AudioClassID *requestedClasses = qualifierData;
    UInt32 requestedClassCount = qualifierDataSize / sizeof(AudioClassID);
    UInt32 resultCount = 0;
    for (UInt32 candidateIndex = 0;
         candidateIndex < candidateCount;
         ++candidateIndex) {
        Boolean matches = requestedClassCount == 0;
        for (UInt32 classIndex = 0;
             classIndex < requestedClassCount && !matches;
             ++classIndex) {
            matches = ObjectMatchesClass(candidates[candidateIndex],
                                         requestedClasses[classIndex]);
        }
        if (matches) {
            if (output != NULL) {
                output[resultCount] = candidates[candidateIndex];
            }
            ++resultCount;
        }
    }
    *outCount = resultCount;
    return noErr;
}

static Boolean HasCommonProperty(AudioObjectPropertySelector selector) {
    switch (selector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
            return true;
        default:
            return false;
    }
}

static Boolean HasPluginProperty(AudioObjectPropertySelector selector) {
    switch (selector) {
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyClockDeviceList:
        case kAudioPlugInPropertyTranslateUIDToClockDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static Boolean HasDeviceProperty(AudioObjectPropertySelector selector) {
    switch (selector) {
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyActualSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyHogMode:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyBufferFrameSizeRange:
        case kAudioDevicePropertyIOCycleUsage:
        case kAudioDevicePropertyStreamConfiguration:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyClockAlgorithm:
        case kAudioDevicePropertyClockIsStable:
            return true;
        default:
            return false;
    }
}

static Boolean HasStreamProperty(AudioObjectPropertySelector selector) {
    switch (selector) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static Boolean HasControlProperty(AudioObjectID objectID,
                                  AudioObjectPropertySelector selector) {
    if (selector == kAudioControlPropertyScope
        || selector == kAudioControlPropertyElement) {
        return true;
    }
    if (objectID == kSVCObjectVolume) {
        switch (selector) {
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyDecibelRange:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                return true;
            default:
                return false;
        }
    }
    return objectID == kSVCObjectMute
        && selector == kAudioBooleanControlPropertyValue;
}

static Boolean IsValidAddress(AudioObjectID objectID,
                              const AudioObjectPropertyAddress *address) {
    if (address->mElement != kAudioObjectPropertyElementMain) {
        return false;
    }
    if (objectID == kSVCObjectPlugin
        || objectID == kSVCObjectOutputStream
        || objectID == kSVCObjectVolume
        || objectID == kSVCObjectMute) {
        return address->mScope == kAudioObjectPropertyScopeGlobal;
    }

    if (objectID != kSVCObjectDevice) {
        return false;
    }
    switch (address->mSelector) {
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyStreamConfiguration:
            return address->mScope == kAudioObjectPropertyScopeGlobal
                || address->mScope == kAudioObjectPropertyScopeInput
                || address->mScope == kAudioObjectPropertyScopeOutput;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            return address->mScope == kAudioObjectPropertyScopeInput
                || address->mScope == kAudioObjectPropertyScopeOutput;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            return address->mScope == kAudioObjectPropertyScopeOutput;
        default:
            return address->mScope == kAudioObjectPropertyScopeGlobal;
    }
}

static HRESULT STDMETHODCALLTYPE DriverQueryInterface(void *inDriver,
                                                       REFIID inUUID,
                                                       LPVOID *outInterface) {
    if (outInterface == NULL) {
        return E_POINTER;
    }
    *outInterface = NULL;
    if (inDriver != gDriverRef) {
        return E_NOINTERFACE;
    }

    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    if (uuid == NULL) {
        return E_NOINTERFACE;
    }
    Boolean supported = CFEqual(uuid, IUnknownUUID)
        || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(uuid);
    if (!supported) {
        return E_NOINTERFACE;
    }

    (void)atomic_fetch_add_explicit(&gReferenceCount, 1, memory_order_relaxed);
    *outInterface = gDriverRef;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE DriverAddRef(void *inDriver) {
    if (inDriver != gDriverRef) {
        return 0;
    }
    return atomic_fetch_add_explicit(&gReferenceCount, 1, memory_order_relaxed) + 1;
}

static ULONG STDMETHODCALLTYPE DriverRelease(void *inDriver) {
    if (inDriver != gDriverRef) {
        return 0;
    }
    UInt32 current = atomic_load_explicit(&gReferenceCount, memory_order_relaxed);
    while (current > 1) {
        if (atomic_compare_exchange_weak_explicit(&gReferenceCount,
                                                  &current,
                                                  current - 1,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
            return current - 1;
        }
    }
    return 1;
}

static OSStatus DriverInitialize(AudioServerPlugInDriverRef inDriver,
                                 AudioServerPlugInHostRef inHost) {
    if (!IsDriver(inDriver) || inHost == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    gHost = inHost;
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.numer == 0) {
        return kAudioHardwareUnspecifiedError;
    }
    gHostTicksPerFrame = (1000000000.0 / (Float64)kSVCSampleRate)
        * ((Float64)timebase.denom / (Float64)timebase.numer);
    atomic_store_explicit(&gTimestampAnchor, mach_absolute_time(), memory_order_release);
    return InitializeSharedAudio();
}

static OSStatus DriverCreateDevice(AudioServerPlugInDriverRef inDriver,
                                   CFDictionaryRef inDescription,
                                   const AudioServerPlugInClientInfo *inClientInfo,
                                   AudioObjectID *outDeviceObjectID) {
    SVC_UNUSED(inDescription);
    SVC_UNUSED(inClientInfo);
    SVC_UNUSED(outDeviceObjectID);
    return IsDriver(inDriver) ? kAudioHardwareUnsupportedOperationError
                              : kAudioHardwareIllegalOperationError;
}

static OSStatus DriverDestroyDevice(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID) {
    SVC_UNUSED(inDeviceObjectID);
    return IsDriver(inDriver) ? kAudioHardwareUnsupportedOperationError
                              : kAudioHardwareIllegalOperationError;
}

static OSStatus ValidateDeviceCall(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inDeviceObjectID) {
    if (!IsDriver(inDriver)) {
        return kAudioHardwareIllegalOperationError;
    }
    return inDeviceObjectID == kSVCObjectDevice
        ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus DriverAddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo *inClientInfo) {
    SVC_UNUSED(inClientInfo);
    return ValidateDeviceCall(inDriver, inDeviceObjectID);
}

static OSStatus DriverRemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo *inClientInfo) {
    SVC_UNUSED(inClientInfo);
    return ValidateDeviceCall(inDriver, inDeviceObjectID);
}

static OSStatus DriverPerformDeviceConfigurationChange(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction,
    void *inChangeInfo) {
    SVC_UNUSED(inChangeAction);
    SVC_UNUSED(inChangeInfo);
    return ValidateDeviceCall(inDriver, inDeviceObjectID);
}

static OSStatus DriverAbortDeviceConfigurationChange(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction,
    void *inChangeInfo) {
    SVC_UNUSED(inChangeAction);
    SVC_UNUSED(inChangeInfo);
    return ValidateDeviceCall(inDriver, inDeviceObjectID);
}

static Boolean DriverHasProperty(AudioServerPlugInDriverRef inDriver,
                                 AudioObjectID inObjectID,
                                 pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress *inAddress) {
    SVC_UNUSED(inClientProcessID);
    if (!IsDriver(inDriver) || !IsKnownObject(inObjectID) || inAddress == NULL
        || !IsValidAddress(inObjectID, inAddress)) {
        return false;
    }
    if (HasCommonProperty(inAddress->mSelector)) {
        return true;
    }
    switch (inObjectID) {
        case kSVCObjectPlugin:
            return HasPluginProperty(inAddress->mSelector);
        case kSVCObjectDevice:
            return HasDeviceProperty(inAddress->mSelector);
        case kSVCObjectOutputStream:
            return HasStreamProperty(inAddress->mSelector);
        case kSVCObjectVolume:
        case kSVCObjectMute:
            return HasControlProperty(inObjectID, inAddress->mSelector);
        default:
            return false;
    }
}

static OSStatus DriverIsPropertySettable(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    Boolean *outIsSettable) {
    if (outIsSettable == NULL || inAddress == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!DriverHasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return IsKnownObject(inObjectID) ? kAudioHardwareUnknownPropertyError
                                         : kAudioHardwareBadObjectError;
    }
    Boolean isStream = inObjectID == kSVCObjectOutputStream;
    *outIsSettable = (isStream
                      && (inAddress->mSelector == kAudioStreamPropertyIsActive
                          || inAddress->mSelector
                              == kAudioStreamPropertyVirtualFormat
                          || inAddress->mSelector
                              == kAudioStreamPropertyPhysicalFormat))
        || (inObjectID == kSVCObjectDevice
            && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)
        || (inObjectID == kSVCObjectVolume
            && (inAddress->mSelector == kAudioLevelControlPropertyScalarValue
                || inAddress->mSelector == kAudioLevelControlPropertyDecibelValue))
        || (inObjectID == kSVCObjectMute
            && inAddress->mSelector == kAudioBooleanControlPropertyValue);
    return noErr;
}

static OSStatus CommonPropertyDataSize(AudioObjectID objectID,
                                       const AudioObjectPropertyAddress *address,
                                       UInt32 qualifierDataSize,
                                       const void *qualifierData,
                                       UInt32 *outDataSize) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        {
            UInt32 count = 0;
            OSStatus status = FilteredOwnedObjects(objectID, address->mScope,
                                                   qualifierDataSize,
                                                   qualifierData, NULL, &count);
            *outDataSize = count * sizeof(AudioObjectID);
            return status;
        }
        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = 0;
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus PluginPropertyDataSize(AudioObjectPropertySelector selector,
                                       UInt32 *outDataSize) {
    switch (selector) {
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToClockDevice:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList:
            *outDataSize = 0;
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DevicePropertyDataSize(const AudioObjectPropertyAddress *address,
                                       UInt32 *outDataSize) {
    switch (address->mSelector) {
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyClockAlgorithm:
        case kAudioDevicePropertyClockIsStable:
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyHogMode:
            *outDataSize = sizeof(pid_t);
            return noErr;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioDevicePropertyStreams:
            *outDataSize = address->mScope == kAudioObjectPropertyScopeInput
                ? 0 : sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyControlList:
            *outDataSize = address->mScope == kAudioObjectPropertyScopeInput
                ? 0 : 2 * sizeof(AudioObjectID);
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyActualSampleRate:
            *outDataSize = sizeof(Float64);
            return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return noErr;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyBufferFrameSizeRange:
            *outDataSize = sizeof(AudioValueRange);
            return noErr;
        case kAudioDevicePropertyIOCycleUsage:
            *outDataSize = sizeof(Float32);
            return noErr;
        case kAudioDevicePropertyStreamConfiguration:
            *outDataSize = sizeof(AudioBufferList);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamPropertyDataSize(AudioObjectPropertySelector selector,
                                       UInt32 *outDataSize) {
    switch (selector) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus ControlPropertyDataSize(AudioObjectID objectID,
                                        AudioObjectPropertySelector selector,
                                        UInt32 *outDataSize) {
    if (selector == kAudioControlPropertyScope
        || selector == kAudioControlPropertyElement) {
        *outDataSize = sizeof(UInt32);
        return noErr;
    }
    if (objectID == kSVCObjectVolume) {
        switch (selector) {
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                *outDataSize = sizeof(Float32);
                return noErr;
            case kAudioLevelControlPropertyDecibelRange:
                *outDataSize = sizeof(AudioValueRange);
                return noErr;
            default:
                break;
        }
    } else if (objectID == kSVCObjectMute
               && selector == kAudioBooleanControlPropertyValue) {
        *outDataSize = sizeof(UInt32);
        return noErr;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus DriverGetPropertyDataSize(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 *outDataSize) {
    SVC_UNUSED(inQualifierDataSize);
    SVC_UNUSED(inQualifierData);
    if (outDataSize == NULL || inAddress == NULL || !IsDriver(inDriver)) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!IsKnownObject(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (!DriverHasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (HasCommonProperty(inAddress->mSelector)) {
        return CommonPropertyDataSize(inObjectID, inAddress,
                                      inQualifierDataSize, inQualifierData,
                                      outDataSize);
    }
    switch (inObjectID) {
        case kSVCObjectPlugin:
            return PluginPropertyDataSize(inAddress->mSelector, outDataSize);
        case kSVCObjectDevice:
            return DevicePropertyDataSize(inAddress, outDataSize);
        case kSVCObjectOutputStream:
            return StreamPropertyDataSize(inAddress->mSelector, outDataSize);
        case kSVCObjectVolume:
        case kSVCObjectMute:
            return ControlPropertyDataSize(inObjectID,
                                           inAddress->mSelector,
                                           outDataSize);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus CopyData(UInt32 requiredSize,
                         const void *source,
                         UInt32 inDataSize,
                         UInt32 *outDataSize,
                         void *outData) {
    if (outDataSize == NULL || (requiredSize > 0 && outData == NULL)) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inDataSize < requiredSize) {
        return kAudioHardwareBadPropertySizeError;
    }
    if (requiredSize > 0) {
        memcpy(outData, source, requiredSize);
    }
    *outDataSize = requiredSize;
    return noErr;
}

static OSStatus GetCommonPropertyData(AudioObjectID objectID,
                                      const AudioObjectPropertyAddress *address,
                                      UInt32 qualifierDataSize,
                                      const void *qualifierData,
                                      UInt32 inDataSize,
                                      UInt32 *outDataSize,
                                      void *outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            AudioClassID value = BaseClassForObject(objectID);
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyClass: {
            AudioClassID value = ClassForObject(objectID);
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyOwner: {
            AudioObjectID value = OwnerForObject(objectID);
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyName: {
            CFStringRef value = CopyNameForObject(objectID);
            if (value == NULL) {
                return kAudioHardwareUnspecifiedError;
            }
            OSStatus status = CopyData(sizeof(value), &value,
                                       inDataSize, outDataSize, outData);
            if (status != noErr) {
                CFRelease(value);
            }
            return status;
        }
        case kAudioObjectPropertyManufacturer: {
            CFStringRef value = CFRetain(CFSTR(SVC_MANUFACTURER_NAME));
            OSStatus status = CopyData(sizeof(value), &value,
                                       inDataSize, outDataSize, outData);
            if (status != noErr) {
                CFRelease(value);
            }
            return status;
        }
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID objects[4] = {0};
            UInt32 count = 0;
            OSStatus status = FilteredOwnedObjects(objectID, address->mScope,
                                                   qualifierDataSize,
                                                   qualifierData,
                                                   objects, &count);
            if (status != noErr) {
                return status;
            }
            UInt32 size = count * sizeof(AudioObjectID);
            return CopyData(size, objects, inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyCustomPropertyInfoList:
            return CopyData(0, NULL, inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetPluginPropertyData(
    const AudioObjectPropertyAddress *address,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData) {
    switch (address->mSelector) {
        case kAudioPlugInPropertyBundleID: {
            CFStringRef value = CFRetain(CFSTR(SVC_BUNDLE_ID));
            OSStatus status = CopyData(sizeof(value), &value,
                                       inDataSize, outDataSize, outData);
            if (status != noErr) {
                CFRelease(value);
            }
            return status;
        }
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID value = kSVCObjectDevice;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize != sizeof(CFStringRef)
                || inQualifierData == NULL) {
                return kAudioHardwareBadPropertySizeError;
            }
            CFStringRef uid = *(const CFStringRef *)inQualifierData;
            AudioObjectID value = uid != NULL
                && CFEqual(uid, CFSTR(SVC_DEVICE_UID))
                ? kSVCObjectDevice : kAudioObjectUnknown;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList:
            return CopyData(0, NULL, inDataSize, outDataSize, outData);
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToClockDevice: {
            AudioObjectID value = kAudioObjectUnknown;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioPlugInPropertyResourceBundle: {
            CFStringRef value = CFRetain(CFSTR(""));
            OSStatus status = CopyData(sizeof(value), &value,
                                       inDataSize, outDataSize, outData);
            if (status != noErr) {
                CFRelease(value);
            }
            return status;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDevicePropertyData(
    const AudioObjectPropertyAddress *address,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData) {
    switch (address->mSelector) {
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: {
            CFStringRef value = address->mSelector == kAudioDevicePropertyDeviceUID
                ? CFRetain(CFSTR(SVC_DEVICE_UID))
                : CFRetain(CFSTR(SVC_MODEL_UID));
            OSStatus status = CopyData(sizeof(value), &value,
                                       inDataSize, outDataSize, outData);
            if (status != noErr) {
                CFRelease(value);
            }
            return status;
        }
        case kAudioDevicePropertyTransportType: {
            UInt32 value = kAudioDeviceTransportTypeVirtual;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyRelatedDevices: {
            AudioObjectID value = kSVCObjectDevice;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden: {
            UInt32 value = 0;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyClockIsStable: {
            UInt32 value = 1;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyDeviceIsRunning: {
            UInt32 value = atomic_load_explicit(&gRunningCount, memory_order_relaxed) > 0;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: {
            UInt32 value = address->mScope == kAudioObjectPropertyScopeInput ? 0 : 1;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyStreams: {
            AudioObjectID value = kSVCObjectOutputStream;
            if (address->mScope == kAudioObjectPropertyScopeInput) {
                return CopyData(0, NULL, inDataSize, outDataSize, outData);
            }
            return CopyData(sizeof(value), &value,
                            inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyControlList: {
            AudioObjectID values[] = {kSVCObjectVolume, kSVCObjectMute};
            UInt32 size = address->mScope == kAudioObjectPropertyScopeInput
                ? 0 : sizeof(values);
            return CopyData(size, values, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyActualSampleRate: {
            Float64 value = kSVCSampleRate;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange value = {kSVCSampleRate, kSVCSampleRate};
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 values[] = {1, 2};
            return CopyData(sizeof(values), values, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyHogMode: {
            pid_t value = -1;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyBufferFrameSize: {
            UInt32 value = kSVCBufferFrameSize;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyBufferFrameSizeRange: {
            AudioValueRange value = {64, 4096};
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyIOCycleUsage: {
            Float32 value = 0.0f;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyStreamConfiguration: {
            AudioBufferList value = {
                .mNumberBuffers = address->mScope
                    == kAudioObjectPropertyScopeInput ? 0 : 1,
                .mBuffers = {{
                    .mNumberChannels = kSVCChannelCount,
                    .mDataByteSize = 0,
                    .mData = NULL,
                }},
            };
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: {
            UInt32 value = kSVCZeroTimestampPeriod;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyClockAlgorithm: {
            UInt32 value = kAudioDeviceClockAlgorithmRaw;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamPropertyData(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData) {
    SVC_UNUSED(objectID);
    switch (selector) {
        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 value = gOutputStreamActive;
            pthread_mutex_unlock(&gStateMutex);
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyDirection: {
            UInt32 value = 0;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyTerminalType: {
            UInt32 value = kAudioStreamTerminalTypeSpeaker;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyStartingChannel: {
            UInt32 value = 1;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyLatency: {
            UInt32 value = 0;
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription value = StreamFormat();
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription value = {
                .mFormat = StreamFormat(),
                .mSampleRateRange = {kSVCSampleRate, kSVCSampleRate},
            };
            return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetControlPropertyData(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData) {
    if (selector == kAudioControlPropertyScope) {
        UInt32 value = kAudioObjectPropertyScopeOutput;
        return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
    }
    if (selector == kAudioControlPropertyElement) {
        UInt32 value = kAudioObjectPropertyElementMain;
        return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
    }
    if (objectID == kSVCObjectVolume) {
        pthread_mutex_lock(&gStateMutex);
        Float32 scalar = gVolumeScalar;
        pthread_mutex_unlock(&gStateMutex);
        switch (selector) {
            case kAudioLevelControlPropertyScalarValue:
                return CopyData(sizeof(scalar), &scalar,
                                inDataSize, outDataSize, outData);
            case kAudioLevelControlPropertyDecibelValue: {
                Float32 value = SVCVolumeScalarToDecibels(scalar);
                return CopyData(sizeof(value), &value,
                                inDataSize, outDataSize, outData);
            }
            case kAudioLevelControlPropertyDecibelRange: {
                AudioValueRange value = {
                    SVC_VOLUME_MINIMUM_DECIBELS,
                    SVC_VOLUME_MAXIMUM_DECIBELS,
                };
                return CopyData(sizeof(value), &value,
                                inDataSize, outDataSize, outData);
            }
            case kAudioLevelControlPropertyConvertScalarToDecibels: {
                if (inDataSize < sizeof(Float32) || outData == NULL) {
                    return kAudioHardwareBadPropertySizeError;
                }
                Float32 value = SVCVolumeScalarToDecibels(*(Float32 *)outData);
                return CopyData(sizeof(value), &value,
                                inDataSize, outDataSize, outData);
            }
            case kAudioLevelControlPropertyConvertDecibelsToScalar: {
                if (inDataSize < sizeof(Float32) || outData == NULL) {
                    return kAudioHardwareBadPropertySizeError;
                }
                Float32 value = SVCVolumeDecibelsToScalar(*(Float32 *)outData);
                return CopyData(sizeof(value), &value,
                                inDataSize, outDataSize, outData);
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }
    if (objectID == kSVCObjectMute
        && selector == kAudioBooleanControlPropertyValue) {
        pthread_mutex_lock(&gStateMutex);
        UInt32 value = gMute;
        pthread_mutex_unlock(&gStateMutex);
        return CopyData(sizeof(value), &value, inDataSize, outDataSize, outData);
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus DriverGetPropertyData(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    UInt32 *outDataSize,
    void *outData) {
    if (inAddress == NULL || outDataSize == NULL || !IsDriver(inDriver)) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!IsKnownObject(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }
    if (!DriverHasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (HasCommonProperty(inAddress->mSelector)) {
        return GetCommonPropertyData(inObjectID, inAddress,
                                     inQualifierDataSize, inQualifierData,
                                     inDataSize, outDataSize, outData);
    }
    switch (inObjectID) {
        case kSVCObjectPlugin:
            return GetPluginPropertyData(inAddress, inQualifierDataSize,
                                         inQualifierData, inDataSize,
                                         outDataSize, outData);
        case kSVCObjectDevice:
            return GetDevicePropertyData(inAddress, inDataSize,
                                         outDataSize, outData);
        case kSVCObjectOutputStream:
            return GetStreamPropertyData(inObjectID, inAddress->mSelector,
                                         inDataSize,
                                         outDataSize, outData);
        case kSVCObjectVolume:
        case kSVCObjectMute:
            return GetControlPropertyData(inObjectID, inAddress->mSelector,
                                          inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus DriverSetPropertyData(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress,
    UInt32 inQualifierDataSize,
    const void *inQualifierData,
    UInt32 inDataSize,
    const void *inData) {
    SVC_UNUSED(inClientProcessID);
    SVC_UNUSED(inQualifierDataSize);
    SVC_UNUSED(inQualifierData);
    if (!IsDriver(inDriver) || inAddress == NULL || inData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!IsKnownObject(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }

    if (inObjectID == kSVCObjectOutputStream
        && inAddress->mSelector == kAudioStreamPropertyIsActive) {
        if (inDataSize != sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        UInt32 value = *(const UInt32 *)inData != 0;
        pthread_mutex_lock(&gStateMutex);
        Boolean changed = gOutputStreamActive != value;
        gOutputStreamActive = value;
        pthread_mutex_unlock(&gStateMutex);
        if (changed) {
            AudioObjectPropertyAddress changedAddress =
                Address(kAudioStreamPropertyIsActive);
            Notify(inObjectID, 1, &changedAddress);
        }
        return noErr;
    }

    if (inObjectID == kSVCObjectDevice
        && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) {
            return kAudioHardwareBadPropertySizeError;
        }
        return *(const Float64 *)inData == kSVCSampleRate
            ? noErr : kAudioHardwareIllegalOperationError;
    }

    if (inObjectID == kSVCObjectOutputStream
        && (inAddress->mSelector == kAudioStreamPropertyVirtualFormat
            || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        AudioStreamBasicDescription requested =
            *(const AudioStreamBasicDescription *)inData;
        AudioStreamBasicDescription supported = StreamFormat();
        return memcmp(&requested, &supported, sizeof(supported)) == 0
            ? noErr : kAudioDeviceUnsupportedFormatError;
    }

    if (inObjectID == kSVCObjectVolume
        && (inAddress->mSelector == kAudioLevelControlPropertyScalarValue
            || inAddress->mSelector == kAudioLevelControlPropertyDecibelValue)) {
        if (inDataSize != sizeof(Float32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        Float32 raw = *(const Float32 *)inData;
        Float32 value = inAddress->mSelector
            == kAudioLevelControlPropertyScalarValue
            ? SVCVolumeClampScalar(raw) : SVCVolumeDecibelsToScalar(raw);
        pthread_mutex_lock(&gStateMutex);
        Boolean changed = gVolumeScalar != value;
        gVolumeScalar = value;
        pthread_mutex_unlock(&gStateMutex);
        if (changed) {
            AudioObjectPropertyAddress changedAddresses[] = {
                Address(kAudioLevelControlPropertyScalarValue),
                Address(kAudioLevelControlPropertyDecibelValue),
            };
            Notify(kSVCObjectVolume, 2, changedAddresses);
        }
        return noErr;
    }

    if (inObjectID == kSVCObjectMute
        && inAddress->mSelector == kAudioBooleanControlPropertyValue) {
        if (inDataSize != sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        UInt32 value = *(const UInt32 *)inData != 0;
        pthread_mutex_lock(&gStateMutex);
        Boolean changed = gMute != value;
        gMute = value;
        pthread_mutex_unlock(&gStateMutex);
        if (changed) {
            AudioObjectPropertyAddress changedAddress =
                Address(kAudioBooleanControlPropertyValue);
            Notify(kSVCObjectMute, 1, &changedAddress);
        }
        return noErr;
    }

    Boolean settable = false;
    OSStatus status = DriverIsPropertySettable(inDriver, inObjectID, 0,
                                               inAddress, &settable);
    if (status != noErr) {
        return status;
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DriverStartIO(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inDeviceObjectID,
                              UInt32 inClientID) {
    SVC_UNUSED(inClientID);
    OSStatus status = ValidateDeviceCall(inDriver, inDeviceObjectID);
    if (status != noErr) {
        return status;
    }
    UInt32 previous = atomic_fetch_add_explicit(&gRunningCount, 1,
                                                memory_order_acq_rel);
    if (previous == 0) {
        atomic_store_explicit(&gTimestampAnchor, mach_absolute_time(),
                              memory_order_release);
        ResetSharedAudioStream();
        AudioObjectPropertyAddress changed =
            Address(kAudioDevicePropertyDeviceIsRunning);
        Notify(kSVCObjectDevice, 1, &changed);
    }
    return noErr;
}

static OSStatus DriverStopIO(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inDeviceObjectID,
                             UInt32 inClientID) {
    SVC_UNUSED(inClientID);
    OSStatus status = ValidateDeviceCall(inDriver, inDeviceObjectID);
    if (status != noErr) {
        return status;
    }
    UInt32 current = atomic_load_explicit(&gRunningCount, memory_order_acquire);
    while (current > 0) {
        if (atomic_compare_exchange_weak_explicit(&gRunningCount,
                                                  &current,
                                                  current - 1,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) {
            if (current == 1) {
                SVCSharedAudio *gSharedAudio = AcquireAudio();
                if (SVCSharedAudioIsValid(gSharedAudio)) {
                    atomic_store_explicit(&gSharedAudio->writerActive, 0,
                                          memory_order_release);
                }
                ReleaseAudio();
                AudioObjectPropertyAddress changed =
                    Address(kAudioDevicePropertyDeviceIsRunning);
                Notify(kSVCObjectDevice, 1, &changed);
            }
            return noErr;
        }
    }
    return kAudioHardwareIllegalOperationError;
}

static OSStatus DriverGetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       UInt32 inClientID,
                                       Float64 *outSampleTime,
                                       UInt64 *outHostTime,
                                       UInt64 *outSeed) {
    SVC_UNUSED(inClientID);
    OSStatus status = ValidateDeviceCall(inDriver, inDeviceObjectID);
    if (status != noErr) {
        return status;
    }
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL
        || gHostTicksPerFrame <= 0.0) {
        return kAudioHardwareIllegalOperationError;
    }
    UInt64 anchor = atomic_load_explicit(&gTimestampAnchor, memory_order_acquire);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kSVCZeroTimestampPeriod;
    UInt64 periodCount = now > anchor
        ? (UInt64)(((Float64)(now - anchor)) / ticksPerPeriod) : 0;
    *outSampleTime = (Float64)periodCount * kSVCZeroTimestampPeriod;
    *outHostTime = anchor + (UInt64)((Float64)periodCount * ticksPerPeriod);
    *outSeed = 1;
    return noErr;
}

static OSStatus DriverWillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID,
                                        UInt32 inOperationID,
                                        Boolean *outWillDo,
                                        Boolean *outWillDoInPlace) {
    SVC_UNUSED(inClientID);
    OSStatus status = ValidateDeviceCall(inDriver, inDeviceObjectID);
    if (status != noErr) {
        return status;
    }
    Boolean willDo = inOperationID
            == kAudioServerPlugInIOOperationProcessOutput
        || inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo != NULL) {
        *outWillDo = willDo;
    }
    if (outWillDoInPlace != NULL) {
        *outWillDoInPlace = true;
    }
    return noErr;
}

static OSStatus DriverBeginIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    SVC_UNUSED(inClientID);
    SVC_UNUSED(inOperationID);
    SVC_UNUSED(inIOBufferFrameSize);
    SVC_UNUSED(inIOCycleInfo);
    return ValidateDeviceCall(inDriver, inDeviceObjectID);
}

static OSStatus DriverDoIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    AudioObjectID inStreamObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
    void *ioMainBuffer,
    void *ioSecondaryBuffer) {
    SVC_UNUSED(inClientID);
    SVC_UNUSED(ioSecondaryBuffer);
    OSStatus status = ValidateDeviceCall(inDriver, inDeviceObjectID);
    if (status != noErr) {
        return status;
    }
    if (inIOCycleInfo == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inStreamObjectID != kSVCObjectOutputStream) {
        return kAudioHardwareBadObjectError;
    }
    if (ioMainBuffer == NULL) {
        return noErr;
    }
    Float64 sampleTime = inIOCycleInfo->mOutputTime.mSampleTime;
    if (inOperationID == kAudioServerPlugInIOOperationProcessOutput) {
        SVCSharedAudio *gSharedAudio = AcquireAudio();
        // Per-client buffers are not a complete mix. Observe this stage for
        // diagnostics only; publishing here can race or double-count clients.
        if (gSharedAudio != NULL) {
            atomic_fetch_add_explicit(&gSharedAudio->processOutputCount, 1,
                                      memory_order_relaxed);
        }
        ReleaseAudio();
        return noErr;
    }
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        SVCSharedAudio *gSharedAudio = AcquireAudio();
        if (gSharedAudio != NULL) {
            atomic_fetch_add_explicit(&gSharedAudio->writeMixCount, 1,
                                      memory_order_relaxed);
        }
        CaptureOutput(gSharedAudio, ioMainBuffer, sampleTime, inIOBufferFrameSize);
        ReleaseAudio();
        return noErr;
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DriverEndIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    SVC_UNUSED(inClientID);
    SVC_UNUSED(inOperationID);
    SVC_UNUSED(inIOBufferFrameSize);
    SVC_UNUSED(inIOCycleInfo);
    return ValidateDeviceCall(inDriver, inDeviceObjectID);
}

static AudioServerPlugInDriverInterface gDriverInterface = {
    ._reserved = NULL,
    .QueryInterface = DriverQueryInterface,
    .AddRef = DriverAddRef,
    .Release = DriverRelease,
    .Initialize = DriverInitialize,
    .CreateDevice = DriverCreateDevice,
    .DestroyDevice = DriverDestroyDevice,
    .AddDeviceClient = DriverAddDeviceClient,
    .RemoveDeviceClient = DriverRemoveDeviceClient,
    .PerformDeviceConfigurationChange = DriverPerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange = DriverAbortDeviceConfigurationChange,
    .HasProperty = DriverHasProperty,
    .IsPropertySettable = DriverIsPropertySettable,
    .GetPropertyDataSize = DriverGetPropertyDataSize,
    .GetPropertyData = DriverGetPropertyData,
    .SetPropertyData = DriverSetPropertyData,
    .StartIO = DriverStartIO,
    .StopIO = DriverStopIO,
    .GetZeroTimeStamp = DriverGetZeroTimeStamp,
    .WillDoIOOperation = DriverWillDoIOOperation,
    .BeginIOOperation = DriverBeginIOOperation,
    .DoIOOperation = DriverDoIOOperation,
    .EndIOOperation = DriverEndIOOperation,
};

__attribute__((visibility("default")))
void *SoundVolumeControl_Create(CFAllocatorRef inAllocator,
                                CFUUIDRef inRequestedTypeUUID) {
    SVC_UNUSED(inAllocator);
    if (inRequestedTypeUUID == NULL
        || !CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    return gDriverRef;
}
