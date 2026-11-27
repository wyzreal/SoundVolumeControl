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

// Four-point cubic interpolation retains more high-frequency detail as the
// read cursor moves between samples. Integer positions need just one ring read.
static bool ReadStereoAt(const SVCSharedAudio *audio, uint64_t start,
                         double position, float output[2]) {
    uint64_t frame = (uint64_t)position;
    float t = (float)(position - (double)frame);
    float a[2], b[2], c[2], d[2];
    if (!SVCSharedAudioLoadFrame(audio, frame, b)) return false;
    if (t == 0) {
        memcpy(output, b, sizeof(b));
        return true;
    }
    if (!SVCSharedAudioLoadFrame(audio, frame + 1, c)
        || !SVCSharedAudioLoadFrame(audio, frame + 2, d)) return false;
    if (frame == start) {
        // Extend the first slope without reading a frame from the previous stream.
        for (size_t i = 0; i < 2; ++i) a[i] = 2 * b[i] - c[i];
    } else if (!SVCSharedAudioLoadFrame(audio, frame - 1, a)) {
        return false;
    }
    for (size_t i = 0; i < 2; ++i) {
        float slope = 0.5f * (c[i] - a[i]);
        float nextSlope = 0.5f * (d[i] - b[i]);
        float delta = c[i] - b[i];
        output[i] = b[i] + t * (slope + t * ((3 * delta - 2 * slope - nextSlope)
                                       + t * (slope + nextSlope - 2 * delta)));
    }
    return true;
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
    double initialFraction = reader->readFrame - (double)integerReadFrame;
    uint64_t required = (uint64_t)(initialFraction
        + (outputFrameCount - 1) * playbackRatio) + 3;
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
        if (!ReadStereoAt(audio, streamStart, reader->readFrame,
                          stereoOutput + (size_t)outputFrame * kSVCSharedAudioChannelCount)) {
            reader->synchronized = false;
            ++reader->underrunCount;
            WriteSilence(stereoOutput, outputFrameCount);
            return 0;
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
