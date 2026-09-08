#include "AudioProcessor.h"

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

int main(void) {
    TestInterleavedRamp();
    TestInterleavedToPlanarAndClamp();
    TestPlanarToInterleaved();
    TestMissingInputProducesSilence();
    puts("audio-processor-tests: PASS");
    return 0;
}
