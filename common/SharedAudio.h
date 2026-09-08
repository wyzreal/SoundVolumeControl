#ifndef SOUND_VOLUME_CONTROL_SHARED_AUDIO_H
#define SOUND_VOLUME_CONTROL_SHARED_AUDIO_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define SVC_SHARED_AUDIO_NAME "/svc-audio-v2"
#define SVC_LEGACY_SHARED_AUDIO_NAME "/svc-audio-v1"
#define SVC_SHARED_AUDIO_MAGIC UINT32_C(0x53564341)
#define SVC_SHARED_AUDIO_VERSION UINT32_C(2)

enum {
    kSVCSharedAudioChannelCount = 2,
    kSVCSharedAudioCapacityFrames = 32768,
};

/*
 * The output-only Core Audio driver writes this single-producer ring and the
 * user-space forwarder maps it read-only. It carries only rendered samples from
 * the Sound Volume virtual output; it is not an input or recording device.
 */
typedef struct {
    _Atomic(uint64_t) tag;
    _Atomic(uint64_t) stereo;
} SVCSharedFrame;

typedef struct {
    _Atomic(uint32_t) magic;
    uint32_t version;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint32_t sampleRate;
    _Atomic(uint32_t) processOutputCount;
    _Atomic(uint64_t) writeFrame;
    _Atomic(uint64_t) streamStartFrame;
    _Atomic(uint64_t) streamEpoch;
    _Atomic(uint32_t) writerActive;
    _Atomic(uint32_t) writeMixCount;
    uint32_t reserved1[2];
    SVCSharedFrame frames[kSVCSharedAudioCapacityFrames];
} SVCSharedAudio;

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2,
               "shared frame access must be lock-free");
_Static_assert(offsetof(SVCSharedAudio, frames) == 64,
               "shared audio header must stay cache-line sized");

static inline bool SVCSharedAudioIsValid(const SVCSharedAudio *audio) {
    return audio != NULL
        && atomic_load_explicit(&audio->magic, memory_order_acquire)
            == SVC_SHARED_AUDIO_MAGIC
        && audio->version == SVC_SHARED_AUDIO_VERSION
        && audio->channelCount == kSVCSharedAudioChannelCount
        && audio->capacityFrames == kSVCSharedAudioCapacityFrames
        && audio->sampleRate > 0;
}

/* Initialize a newly allocated mapping, before making it visible to readers. */
static inline void SVCSharedAudioInitialize(SVCSharedAudio *audio,
                                           uint32_t sampleRate) {
    memset(audio, 0, sizeof(*audio));
    audio->version = SVC_SHARED_AUDIO_VERSION;
    audio->channelCount = kSVCSharedAudioChannelCount;
    audio->capacityFrames = kSVCSharedAudioCapacityFrames;
    audio->sampleRate = sampleRate;
    atomic_init(&audio->magic, 0);
    atomic_init(&audio->processOutputCount, 0);
    atomic_init(&audio->writeMixCount, 0);
    atomic_init(&audio->writeFrame, 0);
    atomic_init(&audio->streamStartFrame, 0);
    atomic_init(&audio->streamEpoch, 0);
    atomic_init(&audio->writerActive, 0);
    for (uint32_t index = 0; index < kSVCSharedAudioCapacityFrames; ++index) {
        atomic_init(&audio->frames[index].tag, 0);
        atomic_init(&audio->frames[index].stereo, 0);
    }
    atomic_store_explicit(&audio->magic, SVC_SHARED_AUDIO_MAGIC,
                          memory_order_release);
}

/* Only the final-mix callback writes frames. Tags reject gaps and overwritten
 * slots; atomic stereo words prevent torn samples during concurrent reads. */
static inline void SVCSharedAudioStoreFrame(SVCSharedAudio *audio,
                                           uint64_t frame,
                                           const float stereo[2]) {
    SVCSharedFrame *slot = &audio->frames[frame % kSVCSharedAudioCapacityFrames];
    uint64_t bits;
    memcpy(&bits, stereo, sizeof(bits));
    atomic_store(&slot->tag, 0);
    atomic_store(&slot->stereo, bits);
    atomic_store(&slot->tag, frame + 1);
}

static inline bool SVCSharedAudioLoadFrame(const SVCSharedAudio *audio,
                                          uint64_t frame, float stereo[2]) {
    const SVCSharedFrame *slot =
        &audio->frames[frame % kSVCSharedAudioCapacityFrames];
    if (atomic_load(&slot->tag) != frame + 1) return false;
    uint64_t bits = atomic_load(&slot->stereo);
    if (atomic_load(&slot->tag) != frame + 1) return false;
    memcpy(stereo, &bits, sizeof(bits));
    return true;
}

#endif
