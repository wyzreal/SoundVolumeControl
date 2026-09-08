#include "SharedAudioReader.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static SVCSharedAudio *NewSharedAudio(void) {
    SVCSharedAudio *audio = calloc(1, sizeof(*audio));
    assert(audio != NULL);
    SVCSharedAudioInitialize(audio, 48000);
    atomic_store(&audio->streamEpoch, 1);
    atomic_store(&audio->writerActive, 1);
    return audio;
}

static void WriteFrames(SVCSharedAudio *audio,
                        uint64_t firstFrame,
                        uint32_t count) {
    for (uint32_t offset = 0; offset < count; ++offset) {
        uint64_t frame = firstFrame + offset;
        float stereo[] = {(float)frame, -(float)frame};
        SVCSharedAudioStoreFrame(audio, frame, stereo);
    }
    atomic_store_explicit(&audio->writeFrame, firstFrame + count,
                          memory_order_release);
}

static void TestWaitsForTargetLatency(void) {
    SVCSharedAudio *audio = NewSharedAudio();
    SVCSharedAudioReader reader;
    SVCSharedAudioReaderInit(&reader, audio, 1024);
    float output[256 * 2];
    memset(output, 0xff, sizeof(output));

    WriteFrames(audio, 0, 512);
    assert(SVCSharedAudioReaderRead(&reader, output, 256) == 0);
    for (size_t index = 0; index < 256 * 2; ++index) {
        assert(output[index] == 0.0f);
    }

    WriteFrames(audio, 512, 1024);
    assert(SVCSharedAudioReaderRead(&reader, output, 256) == 256);
    assert(fabsf(output[0] - 512.0f) < 0.01f);
    assert(fabsf(output[1] + 512.0f) < 0.01f);
    free(audio);
}

static void TestStreamRestartResynchronizes(void) {
    SVCSharedAudio *audio = NewSharedAudio();
    SVCSharedAudioReader reader;
    SVCSharedAudioReaderInit(&reader, audio, 512);
    float output[128 * 2];

    WriteFrames(audio, 0, 1024);
    assert(SVCSharedAudioReaderRead(&reader, output, 128) == 128);
    atomic_store_explicit(&audio->writerActive, 0, memory_order_release);
    assert(SVCSharedAudioReaderRead(&reader, output, 128) == 0);

    uint64_t restart = atomic_load_explicit(&audio->writeFrame,
                                             memory_order_relaxed);
    atomic_store_explicit(&audio->streamStartFrame, restart,
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&audio->streamEpoch, 1, memory_order_release);
    atomic_store_explicit(&audio->writerActive, 1, memory_order_release);
    WriteFrames(audio, restart, 1024);
    assert(SVCSharedAudioReaderRead(&reader, output, 128) == 128);
    assert(fabsf(output[0] - (float)(restart + 512)) < 0.01f);
    free(audio);
}

static void TestRejectsOverwrittenReadPosition(void) {
    SVCSharedAudio *audio = NewSharedAudio();
    SVCSharedAudioReader reader;
    SVCSharedAudioReaderInit(&reader, audio, 512);
    float output[128 * 2];

    WriteFrames(audio, 0, 1024);
    assert(SVCSharedAudioReaderRead(&reader, output, 128) == 128);
    WriteFrames(audio, 1024, kSVCSharedAudioCapacityFrames);
    assert(SVCSharedAudioReaderRead(&reader, output, 128) == 0);
    assert(!reader.synchronized);
    free(audio);
}

static void TestStalledWriterNeverReplaysTail(void) {
    SVCSharedAudio *audio = NewSharedAudio();
    SVCSharedAudioReader reader;
    SVCSharedAudioReaderInit(&reader, audio, 512);
    float output[128 * 2];
    WriteFrames(audio, 0, 1024);
    while (SVCSharedAudioReaderRead(&reader, output, 128) != 0) {}
    double position = reader.readFrame;
    for (int attempt = 0; attempt < 100; ++attempt) {
        assert(SVCSharedAudioReaderRead(&reader, output, 128) == 0);
        assert(reader.readFrame == position);
        for (int index = 0; index < 256; ++index) assert(output[index] == 0);
    }
    WriteFrames(audio, 1024, 512);
    assert(SVCSharedAudioReaderRead(&reader, output, 128) == 128);
    assert(fabs(output[0] - position) < 0.01);
    free(audio);
}

static void TestMissingFramesAreNotOldRingContents(void) {
    SVCSharedAudio *audio = NewSharedAudio();
    SVCSharedAudioReader reader;
    float output[128 * 2];
    WriteFrames(audio, 0, kSVCSharedAudioCapacityFrames);
    SVCSharedAudioReaderInit(&reader, audio, 1024);
    // Publish beyond a gap whose slots still contain last lap's samples.
    WriteFrames(audio, kSVCSharedAudioCapacityFrames + 512, 512);
    assert(SVCSharedAudioReaderRead(&reader, output, 128) == 0);
    for (int index = 0; index < 256; ++index) assert(output[index] == 0);
    free(audio);
}

int main(void) {
    TestWaitsForTargetLatency();
    TestStreamRestartResynchronizes();
    TestRejectsOverwrittenReadPosition();
    TestStalledWriterNeverReplaysTail();
    TestMissingFramesAreNotOldRingContents();
    puts("shared audio reader tests passed");
    return 0;
}
