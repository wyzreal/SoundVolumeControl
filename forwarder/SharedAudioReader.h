#ifndef SOUND_VOLUME_CONTROL_SHARED_AUDIO_READER_H
#define SOUND_VOLUME_CONTROL_SHARED_AUDIO_READER_H

#include "SharedAudio.h"

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    const SVCSharedAudio *sharedAudio;
    double readFrame;
    uint64_t streamEpoch;
    uint64_t underrunCount;
    uint64_t resyncCount;
    uint32_t targetLatencyFrames;
    bool synchronized;
} SVCSharedAudioReader;

void SVCSharedAudioReaderInit(SVCSharedAudioReader *reader,
                              const SVCSharedAudio *sharedAudio,
                              uint32_t targetLatencyFrames);

/* Returns the number of non-silence source frames rendered. */
uint32_t SVCSharedAudioReaderRead(SVCSharedAudioReader *reader,
                                  float *stereoOutput,
                                  uint32_t outputFrameCount);

#endif
