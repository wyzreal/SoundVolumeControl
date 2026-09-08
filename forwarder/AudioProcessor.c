#include "AudioProcessor.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

enum { kSVCMaximumMappedChannels = 64 };

typedef struct {
    const Float32 *samples;
    UInt32 channelCount;
    UInt32 channelIndex;
    UInt32 frameCount;
} SVCInputChannel;

static Float32 ClampGain(Float32 gain) {
    if (!isfinite(gain) || gain < 0.0f) {
        return 0.0f;
    }
    if (gain > 1.0f) {
        return 1.0f;
    }
    return gain;
}

static UInt32 FloatBits(Float32 value) {
    UInt32 bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static Float32 BitsFloat(UInt32 bits) {
    Float32 value = 0.0f;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

void SVCGainProcessorInit(SVCGainProcessor *processor,
                          Float32 initialGain,
                          Float64 sampleRate,
                          Float64 rampMilliseconds) {
    Float32 gain = ClampGain(initialGain);
    UInt32 rampFrames = 1;
    if (isfinite(sampleRate) && sampleRate > 0.0
        && isfinite(rampMilliseconds) && rampMilliseconds > 0.0) {
        Float64 frames = sampleRate * rampMilliseconds / 1000.0;
        if (frames >= 1.0 && frames <= UINT32_MAX) {
            rampFrames = (UInt32)frames;
        }
    }
    atomic_init(&processor->targetGainBits, FloatBits(gain));
    processor->currentGain = gain;
    processor->rampTarget = gain;
    processor->rampFramesRemaining = 0;
    processor->rampLengthFrames = rampFrames;
}

void SVCGainProcessorSetTarget(SVCGainProcessor *processor, Float32 targetGain) {
    atomic_store_explicit(&processor->targetGainBits,
                          FloatBits(ClampGain(targetGain)),
                          memory_order_release);
}

Float32 SVCGainProcessorGetTarget(const SVCGainProcessor *processor) {
    return BitsFloat(atomic_load_explicit(&processor->targetGainBits,
                                          memory_order_acquire));
}

static UInt32 MapInputChannels(const AudioBufferList *input,
                               SVCInputChannel channels[],
                               UInt32 capacity) {
    if (input == NULL) {
        return 0;
    }
    UInt32 mapped = 0;
    for (UInt32 bufferIndex = 0;
         bufferIndex < input->mNumberBuffers && mapped < capacity;
         ++bufferIndex) {
        const AudioBuffer *buffer = &input->mBuffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
            continue;
        }
        UInt32 frameCount = buffer->mDataByteSize
            / (sizeof(Float32) * buffer->mNumberChannels);
        for (UInt32 channelIndex = 0;
             channelIndex < buffer->mNumberChannels && mapped < capacity;
             ++channelIndex) {
            channels[mapped++] = (SVCInputChannel) {
                .samples = buffer->mData,
                .channelCount = buffer->mNumberChannels,
                .channelIndex = channelIndex,
                .frameCount = frameCount,
            };
        }
    }
    return mapped;
}

static UInt32 MaximumOutputFrames(const AudioBufferList *output) {
    UInt32 maximum = 0;
    for (UInt32 bufferIndex = 0;
         bufferIndex < output->mNumberBuffers;
         ++bufferIndex) {
        const AudioBuffer *buffer = &output->mBuffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
            continue;
        }
        UInt32 frames = buffer->mDataByteSize
            / (sizeof(Float32) * buffer->mNumberChannels);
        if (frames > maximum) {
            maximum = frames;
        }
    }
    return maximum;
}

static Float32 GainForNextFrame(SVCGainProcessor *processor) {
    Float32 target = SVCGainProcessorGetTarget(processor);
    if (target != processor->rampTarget) {
        processor->rampTarget = target;
        processor->rampFramesRemaining = processor->rampLengthFrames;
    }
    if (processor->rampFramesRemaining > 0) {
        Float32 distance = processor->rampTarget - processor->currentGain;
        processor->currentGain += distance
            / (Float32)processor->rampFramesRemaining;
        --processor->rampFramesRemaining;
    } else {
        processor->currentGain = processor->rampTarget;
    }
    return processor->currentGain;
}

void SVCGainProcessorProcess(SVCGainProcessor *processor,
                             const AudioBufferList *input,
                             AudioBufferList *output) {
    if (processor == NULL || output == NULL) {
        return;
    }

    SVCInputChannel inputChannels[kSVCMaximumMappedChannels] = {0};
    UInt32 inputChannelCount = MapInputChannels(
        input, inputChannels, kSVCMaximumMappedChannels
    );
    UInt32 maximumFrames = MaximumOutputFrames(output);

    for (UInt32 bufferIndex = 0;
         bufferIndex < output->mNumberBuffers;
         ++bufferIndex) {
        AudioBuffer *buffer = &output->mBuffers[bufferIndex];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }

    UInt32 outputChannelBase = 0;
    for (UInt32 frame = 0; frame < maximumFrames; ++frame) {
        Float32 gain = GainForNextFrame(processor);
        outputChannelBase = 0;
        for (UInt32 bufferIndex = 0;
             bufferIndex < output->mNumberBuffers;
             ++bufferIndex) {
            AudioBuffer *buffer = &output->mBuffers[bufferIndex];
            UInt32 outputChannels = buffer->mNumberChannels;
            if (buffer->mData == NULL || outputChannels == 0) {
                outputChannelBase += outputChannels;
                continue;
            }
            UInt32 outputFrames = buffer->mDataByteSize
                / (sizeof(Float32) * outputChannels);
            if (frame >= outputFrames) {
                outputChannelBase += outputChannels;
                continue;
            }
            Float32 *outputSamples = buffer->mData;
            for (UInt32 channel = 0; channel < outputChannels; ++channel) {
                UInt32 globalChannel = outputChannelBase + channel;
                if (globalChannel >= inputChannelCount) {
                    continue;
                }
                SVCInputChannel source = inputChannels[globalChannel];
                if (frame >= source.frameCount) {
                    continue;
                }
                Float32 sample = source.samples[
                    frame * source.channelCount + source.channelIndex
                ];
                outputSamples[frame * outputChannels + channel] = sample * gain;
            }
            outputChannelBase += outputChannels;
        }
    }
}
