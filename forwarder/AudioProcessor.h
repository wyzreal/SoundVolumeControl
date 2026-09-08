#ifndef SVC_AUDIO_PROCESSOR_H
#define SVC_AUDIO_PROCESSOR_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdatomic.h>

typedef struct {
    _Atomic(UInt32) targetGainBits;
    Float32 currentGain;
    Float32 rampTarget;
    UInt32 rampFramesRemaining;
    UInt32 rampLengthFrames;
} SVCGainProcessor;

void SVCGainProcessorInit(SVCGainProcessor *processor,
                          Float32 initialGain,
                          Float64 sampleRate,
                          Float64 rampMilliseconds);

void SVCGainProcessorSetTarget(SVCGainProcessor *processor, Float32 targetGain);

Float32 SVCGainProcessorGetTarget(const SVCGainProcessor *processor);

void SVCGainProcessorProcess(SVCGainProcessor *processor,
                             const AudioBufferList *input,
                             AudioBufferList *output);

#endif
