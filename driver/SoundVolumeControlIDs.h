#ifndef SOUND_VOLUME_CONTROL_IDS_H
#define SOUND_VOLUME_CONTROL_IDS_H

#include <CoreAudio/AudioServerPlugIn.h>

#define SVC_BUNDLE_ID "org.soundvolumecontrol.driver"
#define SVC_DEVICE_UID "org.soundvolumecontrol.device"
#define SVC_MODEL_UID "org.soundvolumecontrol.model"
#define SVC_DEVICE_NAME "Sound Volume"
#define SVC_MANUFACTURER_NAME "SoundVolumeControl"

enum {
    kSVCObjectPlugin = kAudioObjectPlugInObject,
    kSVCObjectDevice = 2,
    kSVCObjectOutputStream = 3,
    kSVCObjectStream = kSVCObjectOutputStream,
    kSVCObjectVolume = 4,
    kSVCObjectMute = 5,
    kSVCObjectLast = kSVCObjectMute,
};

enum {
    kSVCSampleRate = 48000,
    kSVCChannelCount = 2,
    kSVCBufferFrameSize = 512,
    kSVCZeroTimestampPeriod = 16384,
};

#endif
