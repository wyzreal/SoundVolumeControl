#include "PhysicalOutput.h"

#include <stdlib.h>
#include <string.h>

static const AudioObjectPropertyAddress deviceAddresses[] = {
    {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
    {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
    {kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
};
enum { nominalRate, streams, streamConfig, preferredStereo };
static const AudioObjectPropertyAddress virtualFormat = {
    kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
};
static const AudioObjectPropertyAddress startingChannel = {
    kAudioStreamPropertyStartingChannel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
};

static bool Read(AudioObjectID object, const AudioObjectPropertyAddress *address,
                 void *data, UInt32 size) {
    UInt32 actual = size;
    return AudioObjectGetPropertyData(object, address, 0, NULL, &actual, data) == noErr
        && actual == size;
}

void SVCPhysicalOutputClose(SVCPhysicalOutput *output) {
    for (UInt32 i = 0; i < output->formatListeners; ++i) {
        (void)AudioObjectRemovePropertyListener(output->streams[i], &virtualFormat,
                                                output->listener, NULL);
    }
    for (UInt32 i = 0; i < output->startingChannelListeners; ++i) {
        (void)AudioObjectRemovePropertyListener(output->streams[i], &startingChannel,
                                                output->listener, NULL);
    }
    for (unsigned i = 0; i < output->deviceListeners; ++i) {
        (void)AudioObjectRemovePropertyListener(output->device, &deviceAddresses[i],
                                                output->listener, NULL);
    }
    free(output->streams);
    *output = (SVCPhysicalOutput){0};
}

const char *SVCPhysicalOutputObserve(SVCPhysicalOutput *output,
                                     AudioDeviceID device, Float64 sampleRate,
                                     AudioObjectPropertyListenerProc listener) {
    *output = (SVCPhysicalOutput){.device = device, .sampleRate = sampleRate, .listener = listener};
    output->hasPreferredPair = AudioObjectHasProperty(device, &deviceAddresses[preferredStereo]);
    unsigned count = output->hasPreferredPair ? preferredStereo + 1 : streamConfig + 1;
    for (unsigned i = 0; i < count; ++i) {
        if (AudioObjectAddPropertyListener(device, &deviceAddresses[i], listener, NULL) != noErr) {
            return "Could not monitor the physical output configuration.";
        }
        ++output->deviceListeners;
    }
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &deviceAddresses[streams], 0, NULL, &size) != noErr
        || size == 0 || size % sizeof(AudioStreamID) != 0) {
        return "Could not enumerate the physical output streams.";
    }
    output->streams = malloc(size);
    if (output->streams == NULL || !Read(device, &deviceAddresses[streams], output->streams, size)) {
        return "Could not read the physical output streams.";
    }
    output->streamCount = size / sizeof(AudioStreamID);
    for (UInt32 i = 0; i < output->streamCount; ++i) {
        if (AudioObjectAddPropertyListener(output->streams[i], &virtualFormat, listener, NULL) != noErr) {
            return "Could not monitor the physical output stream format.";
        }
        ++output->formatListeners;
        if (AudioObjectAddPropertyListener(output->streams[i], &startingChannel, listener, NULL) != noErr) {
            return "Could not monitor the physical output channel assignments.";
        }
        ++output->startingChannelListeners;
    }
    return NULL;
}

bool SVCPhysicalFormatSupported(const AudioStreamBasicDescription *format, Float64 sampleRate) {
    if (format->mFormatID != kAudioFormatLinearPCM || format->mSampleRate != sampleRate
        || !(format->mFormatFlags & kAudioFormatFlagIsFloat)
        || (format->mFormatFlags & kAudioFormatFlagIsBigEndian) != kAudioFormatFlagsNativeEndian
        || format->mBitsPerChannel != 32 || format->mFramesPerPacket != 1
        || format->mChannelsPerFrame == 0 || format->mChannelsPerFrame > UINT32_MAX / sizeof(Float32)) {
        return false;
    }
    UInt32 channelsPerBuffer = format->mFormatFlags & kAudioFormatFlagIsNonInterleaved
        ? 1 : format->mChannelsPerFrame;
    return format->mBytesPerFrame == channelsPerBuffer * sizeof(Float32)
        && format->mBytesPerPacket == format->mBytesPerFrame;
}

const char *SVCPhysicalOutputRead(const SVCPhysicalOutput *output, UInt32 stereoChannels[2]) {
    Float64 rate = 0;
    if (!Read(output->device, &deviceAddresses[nominalRate], &rate, sizeof(rate))
        || rate != output->sampleRate) {
        return "Physical output sample-rate mismatch. Set the output to 48 kHz in Audio MIDI Setup.";
    }
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(output->device, &deviceAddresses[streams], 0, NULL, &size) != noErr
        || size != output->streamCount * sizeof(AudioStreamID)) {
        return "The physical output stream list changed. Select the output again.";
    }
    AudioStreamID *current = malloc(size);
    bool same = current && Read(output->device, &deviceAddresses[streams], current, size)
        && memcmp(output->streams, current, size) == 0;
    free(current);
    if (!same) return "The physical output streams changed. Select the output again.";

    UInt32 pair[] = {1, 2};
    if (output->hasPreferredPair && !Read(output->device, &deviceAddresses[preferredStereo],
                                          pair, sizeof(pair))) {
        return "Could not read the preferred stereo channels for the physical output.";
    }
    // Translate one-based device channel numbers to positions in the IOProc's buffers.
    stereoChannels[0] = stereoChannels[1] = UINT32_MAX;
    UInt32 totalChannels = 0;
    for (UInt32 i = 0; i < output->streamCount; ++i) {
        AudioStreamBasicDescription format;
        UInt32 first = 0;
        if (!Read(output->streams[i], &virtualFormat, &format, sizeof(format))
            || !SVCPhysicalFormatSupported(&format, output->sampleRate)) {
            return "The physical output stream must provide native 32-bit floating-point PCM at 48 kHz.";
        }
        if (!Read(output->streams[i], &startingChannel, &first, sizeof(first)) || first == 0
            || format.mChannelsPerFrame > UINT32_MAX - totalChannels) {
            return "Could not determine the physical output channel assignments.";
        }
        for (unsigned side = 0; side < 2; ++side) {
            if (pair[side] >= first && pair[side] - first < format.mChannelsPerFrame) {
                stereoChannels[side] = totalChannels + (pair[side] - first);
            }
        }
        totalChannels += format.mChannelsPerFrame;
    }
    if (totalChannels == 1) {
        stereoChannels[0] = stereoChannels[1] = 0;
    } else if (!output->hasPreferredPair) {
        stereoChannels[0] = 0;
        stereoChannels[1] = 1;
    } else if (stereoChannels[0] == UINT32_MAX || stereoChannels[1] == UINT32_MAX
               || stereoChannels[0] == stereoChannels[1]) {
        return "The physical output has an invalid preferred stereo channel pair.";
    }
    return NULL;
}
