#ifndef SVC_PHYSICAL_OUTPUT_H
#define SVC_PHYSICAL_OUTPUT_H

#include <CoreAudio/AudioHardware.h>
#include <stdbool.h>

// All HAL queries and listener registration run outside the audio callback.
typedef struct {
    AudioDeviceID device;
    Float64 sampleRate;
    AudioObjectPropertyListenerProc listener;
    unsigned deviceListeners;
    bool hasPreferredPair;
    AudioStreamID *streams;
    UInt32 streamCount;
    UInt32 formatListeners;
    UInt32 startingChannelListeners;
} SVCPhysicalOutput;

const char *SVCPhysicalOutputObserve(SVCPhysicalOutput *output,
                                     AudioDeviceID device, Float64 sampleRate,
                                     AudioObjectPropertyListenerProc listener);
const char *SVCPhysicalOutputRead(const SVCPhysicalOutput *output,
                                  UInt32 stereoChannels[2]);
void SVCPhysicalOutputClose(SVCPhysicalOutput *output);

bool SVCPhysicalFormatSupported(const AudioStreamBasicDescription *format,
                                Float64 sampleRate);

#endif
