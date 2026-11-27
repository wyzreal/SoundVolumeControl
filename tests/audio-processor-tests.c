#include "AudioProcessor.h"
#include "PhysicalOutput.h"
#include "OutputActivity.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

typedef struct {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[2];
} TwoBufferList;

static bool Near(Float32 lhs, Float32 rhs) {
    return fabsf(lhs - rhs) < 0.0001f;
}

static void TestInterleavedRamp(void) {
    Float32 inputSamples[] = {1, 1, 1, 1, 1, 1, 1, 1};
    Float32 outputSamples[8] = {0};
    AudioBufferList input = {
        .mNumberBuffers = 1,
        .mBuffers = {{2, sizeof(inputSamples), inputSamples}},
    };
    AudioBufferList output = {
        .mNumberBuffers = 1,
        .mBuffers = {{2, sizeof(outputSamples), outputSamples}},
    };
    SVCGainProcessor processor;
    SVCGainProcessorInit(&processor, 0.5f, 1000.0, 4.0);
    SVCGainProcessorSetTarget(&processor, 1.0f);
    SVCGainProcessorProcess(&processor, &input, &output);

    const Float32 expected[] = {
        0.625f, 0.625f, 0.75f, 0.75f,
        0.875f, 0.875f, 1.0f, 1.0f,
    };
    for (size_t index = 0; index < 8; ++index) {
        assert(Near(outputSamples[index], expected[index]));
    }
}

static void TestInterleavedToPlanarAndClamp(void) {
    Float32 inputSamples[] = {1, 10, 2, 20, 3, 30};
    Float32 left[3] = {0};
    Float32 right[3] = {0};
    AudioBufferList input = {
        .mNumberBuffers = 1,
        .mBuffers = {{2, sizeof(inputSamples), inputSamples}},
    };
    TwoBufferList output = {
        .mNumberBuffers = 2,
        .mBuffers = {
            {1, sizeof(left), left},
            {1, sizeof(right), right},
        },
    };
    SVCGainProcessor processor;
    SVCGainProcessorInit(&processor, 1.0f, 48000.0, 5.0);
    SVCGainProcessorSetTarget(&processor, 8.0f);
    SVCGainProcessorProcess(&processor, &input, (AudioBufferList *)&output);
    assert(Near(left[0], 1) && Near(left[1], 2) && Near(left[2], 3));
    assert(Near(right[0], 10) && Near(right[1], 20) && Near(right[2], 30));
}

static void TestPlanarToInterleaved(void) {
    Float32 left[] = {1, 2};
    Float32 right[] = {3, 4};
    Float32 outputSamples[4] = {0};
    TwoBufferList input = {
        .mNumberBuffers = 2,
        .mBuffers = {
            {1, sizeof(left), left},
            {1, sizeof(right), right},
        },
    };
    AudioBufferList output = {
        .mNumberBuffers = 1,
        .mBuffers = {{2, sizeof(outputSamples), outputSamples}},
    };
    SVCGainProcessor processor;
    SVCGainProcessorInit(&processor, 0.5f, 48000.0, 5.0);
    SVCGainProcessorProcess(&processor, (AudioBufferList *)&input, &output);
    assert(Near(outputSamples[0], 0.5f));
    assert(Near(outputSamples[1], 1.5f));
    assert(Near(outputSamples[2], 1.0f));
    assert(Near(outputSamples[3], 2.0f));
}

static void TestMissingInputProducesSilence(void) {
    Float32 outputSamples[] = {9, 9, 9, 9};
    AudioBufferList output = {
        .mNumberBuffers = 1,
        .mBuffers = {{2, sizeof(outputSamples), outputSamples}},
    };
    SVCGainProcessor processor;
    SVCGainProcessorInit(&processor, 1.0f, 48000.0, 5.0);
    SVCGainProcessorProcess(&processor, NULL, &output);
    for (size_t index = 0; index < 4; ++index) {
        assert(outputSamples[index] == 0.0f);
    }
}

static void TestPhysicalFormatAndChannelMap(void) {
    AudioStreamBasicDescription format = {
        .mFormatID = kAudioFormatLinearPCM, .mSampleRate = 48000,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked, .mFramesPerPacket = 1,
        .mBytesPerPacket = 16, .mBytesPerFrame = 16, .mBitsPerChannel = 32,
        .mChannelsPerFrame = 4
    };
    assert(SVCPhysicalFormatSupported(&format, 48000));
    assert(!SVCPhysicalFormatSupported(&format, 44100));
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger;
    assert(!SVCPhysicalFormatSupported(&format, 48000));
    Float32 stereo[] = {0.25f, 0.75f}, rendered[4];
    AudioBufferList input = {1, {{2, sizeof(stereo), stereo}}};
    AudioBufferList output = {1, {{4, sizeof(rendered), rendered}}};
    SVCGainProcessor processor;
    SVCGainProcessorInit(&processor, 1, 48000, 0);
    SVCGainProcessorSetStereoChannels(&processor, 3, 2);
    SVCGainProcessorProcess(&processor, &input, &output);
    assert(rendered[0] == 0 && rendered[1] == 0 && rendered[2] == 0.75f && rendered[3] == 0.25f);
    SVCGainProcessorSetStereoChannels(&processor, 0, 0);
    SVCGainProcessorProcess(&processor, &input, &output);
    assert(rendered[0] == 0.5f && rendered[1] == 0 && rendered[2] == 0 && rendered[3] == 0);
}

static void TestIdleAndWake(void) {
    uint64_t idle = 0;
    assert(SVCPhysicalIOWanted(true, false, false, 1, &idle));
    assert(!SVCPhysicalIOWanted(true, false, false, 2000000001, &idle));
    assert(SVCPhysicalIOWanted(true, true, false, 2000000002, &idle) && idle == 0);
    assert(SVCPhysicalIOWanted(true, false, true, 2000000003, &idle) && idle == 0);
    assert(SVCPhysicalIOWanted(false, false, false, 2000000004, &idle) && idle == 0);
}

int main(void) {
    TestIdleAndWake();
    TestPhysicalFormatAndChannelMap();
    TestInterleavedRamp();
    TestInterleavedToPlanarAndClamp();
    TestPlanarToInterleaved();
    TestMissingInputProducesSilence();
    puts("audio-processor-tests: PASS");
    return 0;
}
