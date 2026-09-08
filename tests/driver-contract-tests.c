#include "SoundVolumeControlIDs.h"
#include "SharedAudio.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

extern void *SoundVolumeControl_Create(CFAllocatorRef allocator,
                                       CFUUIDRef requestedTypeUUID);
extern SVCSharedAudio *SVCDriverTestSharedAudio(void);

static UInt32 gNotificationCount = 0;
static AudioObjectID gLastNotifiedObject = kAudioObjectUnknown;
static AudioObjectPropertyAddress gLastNotification = {0};

static OSStatus HostPropertiesChanged(
    AudioServerPlugInHostRef host,
    AudioObjectID objectID,
    UInt32 numberAddresses,
    const AudioObjectPropertyAddress *addresses) {
    (void)host;
    gNotificationCount += numberAddresses;
    gLastNotifiedObject = objectID;
    if (numberAddresses > 0 && addresses != NULL) {
        gLastNotification = addresses[numberAddresses - 1];
    }
    return noErr;
}

static OSStatus HostCopyFromStorage(AudioServerPlugInHostRef host,
                                    CFStringRef key,
                                    CFPropertyListRef *outData) {
    (void)host;
    (void)key;
    *outData = NULL;
    return noErr;
}

static OSStatus HostWriteToStorage(AudioServerPlugInHostRef host,
                                   CFStringRef key,
                                   CFPropertyListRef data) {
    (void)host;
    (void)key;
    (void)data;
    return noErr;
}

static OSStatus HostDeleteFromStorage(AudioServerPlugInHostRef host,
                                      CFStringRef key) {
    (void)host;
    (void)key;
    return noErr;
}

static OSStatus HostRequestDeviceConfigurationChange(
    AudioServerPlugInHostRef host,
    AudioObjectID deviceObjectID,
    UInt64 changeAction,
    void *changeInfo) {
    (void)host;
    (void)deviceObjectID;
    (void)changeAction;
    (void)changeInfo;
    return noErr;
}

static AudioServerPlugInHostInterface gHost = {
    .PropertiesChanged = HostPropertiesChanged,
    .CopyFromStorage = HostCopyFromStorage,
    .WriteToStorage = HostWriteToStorage,
    .DeleteFromStorage = HostDeleteFromStorage,
    .RequestDeviceConfigurationChange = HostRequestDeviceConfigurationChange,
};

static AudioObjectPropertyAddress MakeAddress(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress) {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
}

static OSStatus GetData(AudioServerPlugInDriverRef driver,
                        AudioObjectID objectID,
                        AudioObjectPropertyAddress address,
                        UInt32 qualifierSize,
                        const void *qualifier,
                        UInt32 dataSize,
                        UInt32 *outDataSize,
                        void *data) {
    return (*driver)->GetPropertyData(driver, objectID, 0, &address,
                                      qualifierSize, qualifier, dataSize,
                                      outDataSize, data);
}

static OSStatus SetData(AudioServerPlugInDriverRef driver,
                        AudioObjectID objectID,
                        AudioObjectPropertyAddress address,
                        UInt32 dataSize,
                        const void *data) {
    return (*driver)->SetPropertyData(driver, objectID, 0, &address,
                                      0, NULL, dataSize, data);
}

static void TestFactoryAndTopology(AudioServerPlugInDriverRef driver) {
    LPVOID queried = NULL;
    HRESULT result = (*driver)->QueryInterface(
        driver,
        CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID),
        &queried
    );
    assert(result == S_OK);
    assert(queried == driver);
    assert((*driver)->Release(driver) >= 1);

    AudioObjectPropertyAddress address = MakeAddress(
        kAudioPlugInPropertyDeviceList,
        kAudioObjectPropertyScopeGlobal
    );
    UInt32 size = 0;
    assert((*driver)->GetPropertyDataSize(driver, kSVCObjectPlugin, 0,
                                          &address, 0, NULL, &size) == noErr);
    assert(size == sizeof(AudioObjectID));
    AudioObjectID device = kAudioObjectUnknown;
    assert(GetData(driver, kSVCObjectPlugin, address, 0, NULL,
                   sizeof(device), &size, &device) == noErr);
    assert(device == kSVCObjectDevice);

    CFStringRef uid = CFSTR(SVC_DEVICE_UID);
    device = kAudioObjectUnknown;
    address = MakeAddress(kAudioPlugInPropertyTranslateUIDToDevice,
                          kAudioObjectPropertyScopeGlobal);
    assert(GetData(driver, kSVCObjectPlugin, address,
                   sizeof(uid), &uid, sizeof(device), &size, &device) == noErr);
    assert(device == kSVCObjectDevice);

    address = MakeAddress(kAudioDevicePropertyStreams,
                          kAudioObjectPropertyScopeOutput);
    assert((*driver)->GetPropertyDataSize(driver, kSVCObjectDevice, 0,
                                          &address, 0, NULL, &size) == noErr);
    assert(size == sizeof(AudioObjectID));
    AudioObjectID stream = kAudioObjectUnknown;
    assert(GetData(driver, kSVCObjectDevice, address, 0, NULL,
                   sizeof(stream), &size, &stream) == noErr);
    assert(stream == kSVCObjectOutputStream);

    address.mScope = kAudioObjectPropertyScopeInput;
    assert((*driver)->GetPropertyDataSize(driver, kSVCObjectDevice, 0,
                                          &address, 0, NULL, &size) == noErr);
    assert(size == 0);
    assert(GetData(driver, kSVCObjectDevice, address, 0, NULL,
                   0, &size, NULL) == noErr);
    assert(size == 0);

    address.mScope = kAudioObjectPropertyScopeGlobal;
    AudioObjectID streams[1] = {0};
    assert(GetData(driver, kSVCObjectDevice, address, 0, NULL,
                   sizeof(streams), &size, streams) == noErr);
    assert(size == sizeof(streams));
    assert(streams[0] == kSVCObjectOutputStream);

    address = MakeAddress(kAudioObjectPropertyControlList,
                          kAudioObjectPropertyScopeOutput);
    AudioObjectID controls[2] = {0};
    assert(GetData(driver, kSVCObjectDevice, address, 0, NULL,
                   sizeof(controls), &size, controls) == noErr);
    assert(size == sizeof(controls));
    assert(controls[0] == kSVCObjectVolume);
    assert(controls[1] == kSVCObjectMute);

    AudioClassID controlClass = kAudioControlClassID;
    address = MakeAddress(kAudioObjectPropertyOwnedObjects,
                          kAudioObjectPropertyScopeOutput);
    assert((*driver)->GetPropertyDataSize(driver, kSVCObjectDevice, 0,
                                          &address,
                                          sizeof(controlClass), &controlClass,
                                          &size) == noErr);
    assert(size == sizeof(controls));
    memset(controls, 0, sizeof(controls));
    assert(GetData(driver, kSVCObjectDevice, address,
                   sizeof(controlClass), &controlClass,
                   sizeof(controls), &size, controls) == noErr);
    assert(controls[0] == kSVCObjectVolume);
    assert(controls[1] == kSVCObjectMute);

    AudioClassID streamClass = kAudioStreamClassID;
    assert((*driver)->GetPropertyDataSize(driver, kSVCObjectDevice, 0,
                                          &address,
                                          sizeof(streamClass), &streamClass,
                                          &size) == noErr);
    assert(size == sizeof(AudioObjectID));
}

static void TestDeviceAndStream(AudioServerPlugInDriverRef driver) {
    AudioObjectPropertyAddress address = MakeAddress(
        kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioObjectPropertyScopeOutput
    );
    UInt32 size = 0;
    UInt32 value = 0;
    assert(GetData(driver, kSVCObjectDevice, address, 0, NULL,
                   sizeof(value), &size, &value) == noErr);
    assert(value == 1);

    address.mScope = kAudioObjectPropertyScopeInput;
    assert(GetData(driver, kSVCObjectDevice, address, 0, NULL,
                   sizeof(value), &size, &value) == noErr);
    assert(value == 0);

    address = MakeAddress(kAudioDevicePropertyIsHidden,
                          kAudioObjectPropertyScopeGlobal);
    assert(GetData(driver, kSVCObjectDevice, address, 0, NULL,
                   sizeof(value), &size, &value) == noErr);
    assert(value == 0);

    address = MakeAddress(kAudioStreamPropertyVirtualFormat,
                          kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription format = {0};
    assert(GetData(driver, kSVCObjectOutputStream, address, 0, NULL,
                   sizeof(format), &size, &format) == noErr);
    assert(format.mSampleRate == kSVCSampleRate);
    assert(format.mChannelsPerFrame == kSVCChannelCount);
    assert(format.mFormatID == kAudioFormatLinearPCM);
    assert((format.mFormatFlags & kAudioFormatFlagIsFloat) != 0);

    address = MakeAddress(kAudioStreamPropertyIsActive,
                          kAudioObjectPropertyScopeGlobal);
    Boolean settable = false;
    assert((*driver)->IsPropertySettable(driver, kSVCObjectOutputStream, 0,
                                         &address, &settable) == noErr);
    assert(settable);
    value = 0;
    UInt32 before = gNotificationCount;
    assert(SetData(driver, kSVCObjectOutputStream, address,
                   sizeof(value), &value) == noErr);
    assert(gNotificationCount == before + 1);
    assert(gLastNotifiedObject == kSVCObjectOutputStream);
    assert(gLastNotification.mSelector == kAudioStreamPropertyIsActive);
    assert(GetData(driver, kSVCObjectOutputStream, address, 0, NULL,
                   sizeof(value), &size, &value) == noErr);
    assert(value == 0);

    value = 1;
    assert(SetData(driver, kSVCObjectOutputStream, address,
                   sizeof(value), &value) == noErr);

    address = MakeAddress(kAudioStreamPropertyDirection,
                          kAudioObjectPropertyScopeGlobal);
    assert(GetData(driver, kSVCObjectOutputStream, address, 0, NULL,
                   sizeof(value), &size, &value) == noErr);
    assert(value == 0);

    address = MakeAddress(kAudioStreamPropertyVirtualFormat,
                          kAudioObjectPropertyScopeGlobal);
    assert((*driver)->IsPropertySettable(driver, kSVCObjectOutputStream, 0,
                                         &address, &settable) == noErr);
    assert(settable);
    assert(SetData(driver, kSVCObjectOutputStream, address,
                   sizeof(format), &format) == noErr);

    address = MakeAddress(kAudioDevicePropertyNominalSampleRate,
                          kAudioObjectPropertyScopeGlobal);
    Float64 sampleRate = kSVCSampleRate;
    assert((*driver)->IsPropertySettable(driver, kSVCObjectDevice, 0,
                                         &address, &settable) == noErr);
    assert(settable);
    assert(SetData(driver, kSVCObjectDevice, address,
                   sizeof(sampleRate), &sampleRate) == noErr);
}

static void TestVolumeAndMute(AudioServerPlugInDriverRef driver) {
    UInt32 size = 0;
    Boolean settable = false;
    AudioObjectPropertyAddress scalarAddress = MakeAddress(
        kAudioLevelControlPropertyScalarValue,
        kAudioObjectPropertyScopeGlobal
    );
    assert((*driver)->HasProperty(driver, kSVCObjectVolume, 0, &scalarAddress));
    assert((*driver)->IsPropertySettable(driver, kSVCObjectVolume, 0,
                                         &scalarAddress, &settable) == noErr);
    assert(settable);

    Float32 scalar = 0.375f;
    UInt32 before = gNotificationCount;
    assert(SetData(driver, kSVCObjectVolume, scalarAddress,
                   sizeof(scalar), &scalar) == noErr);
    assert(gNotificationCount == before + 2);
    assert(gLastNotifiedObject == kSVCObjectVolume);

    Float32 readScalar = 0.0f;
    assert(GetData(driver, kSVCObjectVolume, scalarAddress, 0, NULL,
                   sizeof(readScalar), &size, &readScalar) == noErr);
    assert(fabsf(readScalar - scalar) < 0.0001f);

    Float32 tooHigh = 2.0f;
    assert(SetData(driver, kSVCObjectVolume, scalarAddress,
                   sizeof(tooHigh), &tooHigh) == noErr);
    assert(GetData(driver, kSVCObjectVolume, scalarAddress, 0, NULL,
                   sizeof(readScalar), &size, &readScalar) == noErr);
    assert(readScalar == 1.0f);

    AudioObjectPropertyAddress decibelAddress = MakeAddress(
        kAudioLevelControlPropertyDecibelValue,
        kAudioObjectPropertyScopeGlobal
    );
    Float32 decibels = -48.0f;
    assert(SetData(driver, kSVCObjectVolume, decibelAddress,
                   sizeof(decibels), &decibels) == noErr);
    assert(GetData(driver, kSVCObjectVolume, scalarAddress, 0, NULL,
                   sizeof(readScalar), &size, &readScalar) == noErr);
    assert(fabsf(readScalar - 0.0630957f) < 0.0001f);

    AudioObjectPropertyAddress conversionAddress = MakeAddress(
        kAudioLevelControlPropertyConvertScalarToDecibels,
        kAudioObjectPropertyScopeGlobal
    );
    Float32 converted = 0.25f;
    assert(GetData(driver, kSVCObjectVolume, conversionAddress, 0, NULL,
                   sizeof(converted), &size, &converted) == noErr);
    assert(fabsf(converted - (-24.0824f)) < 0.0001f);

    AudioObjectPropertyAddress muteAddress = MakeAddress(
        kAudioBooleanControlPropertyValue,
        kAudioObjectPropertyScopeGlobal
    );
    UInt32 mute = 1;
    before = gNotificationCount;
    assert(SetData(driver, kSVCObjectMute, muteAddress,
                   sizeof(mute), &mute) == noErr);
    assert(gNotificationCount == before + 1);
    mute = 0;
    assert(GetData(driver, kSVCObjectMute, muteAddress, 0, NULL,
                   sizeof(mute), &size, &mute) == noErr);
    assert(mute == 1);
}

static void TestIO(AudioServerPlugInDriverRef driver) {
    Boolean willDo = false;
    Boolean inPlace = false;
    assert((*driver)->WillDoIOOperation(
        driver, kSVCObjectDevice, 7,
        kAudioServerPlugInIOOperationWriteMix,
        &willDo, &inPlace
    ) == noErr);
    assert(willDo && inPlace);

    assert((*driver)->WillDoIOOperation(
        driver, kSVCObjectDevice, 7,
        kAudioServerPlugInIOOperationProcessOutput,
        &willDo, &inPlace
    ) == noErr);
    assert(willDo && inPlace);

    assert((*driver)->WillDoIOOperation(
        driver, kSVCObjectDevice, 7,
        kAudioServerPlugInIOOperationReadInput,
        &willDo, &inPlace
    ) == noErr);
    assert(!willDo);

    assert((*driver)->StartIO(driver, kSVCObjectDevice, 7) == noErr);
    SVCSharedAudio *sharedAudio = SVCDriverTestSharedAudio();
    assert(SVCSharedAudioIsValid(sharedAudio));
    assert(atomic_load_explicit(&sharedAudio->writerActive,
                                memory_order_acquire) == 0);
    Float64 sampleTime = -1;
    UInt64 hostTime = 0;
    UInt64 seed = 0;
    assert((*driver)->GetZeroTimeStamp(driver, kSVCObjectDevice, 7,
                                       &sampleTime, &hostTime, &seed) == noErr);
    assert(sampleTime >= 0);
    assert(hostTime > 0);
    assert(seed == 1);

    Float32 frames[kSVCBufferFrameSize * kSVCChannelCount] = {0};
    Float32 secondClient[kSVCBufferFrameSize * kSVCChannelCount] = {0};
    Float32 finalMix[kSVCBufferFrameSize * kSVCChannelCount] = {0};
    for (UInt32 index = 0;
         index < kSVCBufferFrameSize * kSVCChannelCount;
         ++index) {
        frames[index] = 0.25f;
        secondClient[index] = 0.5f;
        finalMix[index] = (Float32)index / 1000.0f;
    }
    AudioServerPlugInIOCycleInfo cycleInfo = {0};
    cycleInfo.mOutputTime.mSampleTime = 2048;
    assert((*driver)->DoIOOperation(
        driver, kSVCObjectDevice, kSVCObjectOutputStream, 7,
        kAudioServerPlugInIOOperationProcessOutput,
        kSVCBufferFrameSize, &cycleInfo, frames, NULL
    ) == noErr);
    assert((*driver)->DoIOOperation(
        driver, kSVCObjectDevice, kSVCObjectOutputStream, 8,
        kAudioServerPlugInIOOperationProcessOutput,
        kSVCBufferFrameSize, &cycleInfo, secondClient, NULL
    ) == noErr);
    // Partial per-client output must not be published or counted twice.
    assert(atomic_load(&sharedAudio->writerActive) == 0);
    assert(atomic_load(&sharedAudio->writeFrame) == 0);
    assert(atomic_load(&sharedAudio->processOutputCount) == 2);

    assert((*driver)->DoIOOperation(
        driver, kSVCObjectDevice, kSVCObjectOutputStream, 7,
        kAudioServerPlugInIOOperationWriteMix,
        kSVCBufferFrameSize, &cycleInfo, finalMix, NULL
    ) == noErr);
    assert(atomic_load(&sharedAudio->writerActive) == 1);
    assert(atomic_load(&sharedAudio->streamStartFrame) == 2048);
    assert(atomic_load(&sharedAudio->writeFrame) == 2048 + kSVCBufferFrameSize);
    assert(atomic_load(&sharedAudio->writeMixCount) == 1);
    for (UInt32 frame = 0; frame < kSVCBufferFrameSize; ++frame) {
        float stereo[2];
        assert(SVCSharedAudioLoadFrame(sharedAudio, 2048 + frame, stereo));
        assert(memcmp(stereo, finalMix + frame * 2, sizeof(stereo)) == 0);
    }
    UInt64 epoch = atomic_load(&sharedAudio->streamEpoch);
    assert((*driver)->StopIO(driver, kSVCObjectDevice, 7) == noErr);
    assert(atomic_load_explicit(&sharedAudio->writerActive,
                                memory_order_acquire) == 0);
    assert((*driver)->StartIO(driver, kSVCObjectDevice, 7) == noErr);
    assert(atomic_load(&sharedAudio->streamEpoch) != epoch);
    float stereo[2];
    assert(!SVCSharedAudioLoadFrame(sharedAudio, 2048, stereo));
    assert((*driver)->StopIO(driver, kSVCObjectDevice, 7) == noErr);
}

static void TestErrors(AudioServerPlugInDriverRef driver) {
    AudioObjectPropertyAddress address = MakeAddress(
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal
    );
    UInt32 size = 0;
    assert((*driver)->GetPropertyDataSize(driver, 999, 0, &address,
                                          0, NULL, &size)
           == kAudioHardwareBadObjectError);
    address.mSelector = 'nope';
    assert((*driver)->GetPropertyDataSize(driver, kSVCObjectDevice, 0,
                                          &address, 0, NULL, &size)
           == kAudioHardwareUnknownPropertyError);
    address = MakeAddress(kAudioObjectPropertyName,
                          kAudioObjectPropertyScopeGlobal);
    address.mElement = 27;
    assert(!(*driver)->HasProperty(driver, kSVCObjectDevice, 0, &address));
    assert((*driver)->GetPropertyDataSize(driver, kSVCObjectDevice, 0,
                                          &address, 0, NULL, &size)
           == kAudioHardwareUnknownPropertyError);
    address.mElement = kAudioObjectPropertyElementMain;
    address.mScope = kAudioObjectPropertyScopeInput;
    assert(!(*driver)->HasProperty(driver, kSVCObjectDevice, 0, &address));
}

int main(void) {
    CFUUIDRef wrongType = CFUUIDCreate(kCFAllocatorDefault);
    assert(SoundVolumeControl_Create(NULL, wrongType) == NULL);
    CFRelease(wrongType);

    AudioServerPlugInDriverRef driver = SoundVolumeControl_Create(
        NULL, kAudioServerPlugInTypeUUID
    );
    assert(driver != NULL);
    assert((*driver)->Initialize(driver, &gHost) == noErr);

    TestFactoryAndTopology(driver);
    TestDeviceAndStream(driver);
    TestVolumeAndMute(driver);
    TestIO(driver);
    TestErrors(driver);

    puts("driver-contract-tests: PASS");
    return 0;
}
