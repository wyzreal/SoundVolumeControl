#include "SharedAudioReader.h"

#include <math.h>
#include <string.h>

static uint32_t ClampTargetLatency(const SVCSharedAudio *audio,
                                   uint32_t requested) {
    uint32_t maximum = audio->capacityFrames / 4;
    uint32_t minimum = 256;
    if (requested < minimum) {
        return minimum;
    }
    return requested > maximum ? maximum : requested;
}

void SVCSharedAudioReaderInit(SVCSharedAudioReader *reader,
                              const SVCSharedAudio *sharedAudio,
                              uint32_t targetLatencyFrames) {
    memset(reader, 0, sizeof(*reader));
    reader->sharedAudio = sharedAudio;
    if (SVCSharedAudioIsValid(sharedAudio)) {
        reader->targetLatencyFrames = ClampTargetLatency(
            sharedAudio, targetLatencyFrames
        );
        reader->streamEpoch = atomic_load_explicit(
            &sharedAudio->streamEpoch, memory_order_acquire
        );
    }
}

static void WriteSilence(float *output, uint32_t frameCount) {
    if (output != NULL && frameCount > 0) {
        memset(output, 0,
               (size_t)frameCount * kSVCSharedAudioChannelCount
               * sizeof(*output));
    }
}

static float ClampCorrection(double correction) {
    if (correction < -0.005) {
        return -0.005f;
    }
    if (correction > 0.005) {
        return 0.005f;
    }
    return (float)correction;
}

uint32_t SVCSharedAudioReaderRead(SVCSharedAudioReader *reader,
                                  float *stereoOutput,
                                  uint32_t outputFrameCount) {
    if (reader == NULL || stereoOutput == NULL || outputFrameCount == 0
        || !SVCSharedAudioIsValid(reader->sharedAudio)) {
        WriteSilence(stereoOutput, outputFrameCount);
        return 0;
    }

    const SVCSharedAudio *audio = reader->sharedAudio;
    if (atomic_load_explicit(&audio->writerActive,
                             memory_order_acquire) == 0) {
        reader->synchronized = false;
        WriteSilence(stereoOutput, outputFrameCount);
        return 0;
    }

    uint64_t epoch = atomic_load_explicit(&audio->streamEpoch,
                                           memory_order_acquire);
    uint64_t writeFrame = atomic_load_explicit(&audio->writeFrame,
                                                memory_order_acquire);
    uint64_t streamStart = atomic_load_explicit(&audio->streamStartFrame,
                                                 memory_order_acquire);
    if (epoch != reader->streamEpoch) {
        reader->streamEpoch = epoch;
        reader->synchronized = false;
    }
    if (writeFrame < streamStart
        || writeFrame - streamStart < reader->targetLatencyFrames) {
        WriteSilence(stereoOutput, outputFrameCount);
        return 0;
    }

    if (!reader->synchronized) {
        reader->readFrame = (double)(writeFrame
            - reader->targetLatencyFrames);
        if (reader->readFrame < (double)streamStart) {
            reader->readFrame = (double)streamStart;
        }
        reader->synchronized = true;
        ++reader->resyncCount;
    }

    uint64_t integerReadFrame = (uint64_t)reader->readFrame;
    if (integerReadFrame > writeFrame
        || writeFrame - integerReadFrame >= audio->capacityFrames - 2) {
        reader->synchronized = false;
        WriteSilence(stereoOutput, outputFrameCount);
        return 0;
    }

    uint64_t available = writeFrame - integerReadFrame;
    double normalizedError = ((double)available
        - (double)reader->targetLatencyFrames)
        / (double)reader->targetLatencyFrames;
    double playbackRatio = 1.0
        + (double)ClampCorrection(normalizedError * 0.01);
    uint64_t required = (uint64_t)ceil(
        (double)outputFrameCount * playbackRatio
    ) + 2;
    if (available < required) {
        // Keep our position while the writer is stalled. Re-synchronizing to
        // writeFrame - latency here would replay the tail indefinitely.
        ++reader->underrunCount;
        WriteSilence(stereoOutput, outputFrameCount);
        return 0;
    }

    for (uint32_t outputFrame = 0;
         outputFrame < outputFrameCount;
         ++outputFrame) {
        uint64_t sourceFrame = (uint64_t)reader->readFrame;
        double fraction = reader->readFrame - (double)sourceFrame;
        float firstStereo[2];
        float secondStereo[2];
        if (!SVCSharedAudioLoadFrame(audio, sourceFrame, firstStereo)
            || !SVCSharedAudioLoadFrame(audio, sourceFrame + 1, secondStereo)) {
            reader->synchronized = false;
            ++reader->underrunCount;
            WriteSilence(stereoOutput, outputFrameCount);
            return 0;
        }
        for (uint32_t channel = 0;
             channel < kSVCSharedAudioChannelCount;
             ++channel) {
            float first = firstStereo[channel];
            float second = secondStereo[channel];
            stereoOutput[
                outputFrame * kSVCSharedAudioChannelCount + channel
            ] = first + (second - first) * (float)fraction;
        }
        reader->readFrame += playbackRatio;
    }
    if (atomic_load_explicit(&audio->streamEpoch, memory_order_acquire) != epoch
        || atomic_load_explicit(&audio->writerActive, memory_order_acquire) == 0) {
        reader->synchronized = false;
        WriteSilence(stereoOutput, outputFrameCount);
        return 0;
    }
    return outputFrameCount;
}
