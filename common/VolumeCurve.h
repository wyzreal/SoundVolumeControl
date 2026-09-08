#ifndef SOUND_VOLUME_CONTROL_VOLUME_CURVE_H
#define SOUND_VOLUME_CONTROL_VOLUME_CURVE_H

#include <CoreAudio/CoreAudioTypes.h>
#include <math.h>

#define SVC_VOLUME_MINIMUM_DECIBELS (-96.0f)
#define SVC_VOLUME_MAXIMUM_DECIBELS (0.0f)

static inline Float32 SVCVolumeClampScalar(Float32 value) {
    if (!isfinite(value) || value <= 0.0f) {
        return 0.0f;
    }
    return value >= 1.0f ? 1.0f : value;
}

/*
 * A square-law amplitude taper keeps the native 0...1 control useful across
 * its whole travel. The finite HAL dB range floors very small positive values
 * at -96 dB; scalar zero is treated as digital silence by the forwarder.
 */
static inline Float32 SVCVolumeScalarToDecibels(Float32 scalar) {
    scalar = SVCVolumeClampScalar(scalar);
    if (scalar == 0.0f) {
        return SVC_VOLUME_MINIMUM_DECIBELS;
    }
    Float32 decibels = 40.0f * log10f(scalar);
    return decibels < SVC_VOLUME_MINIMUM_DECIBELS
        ? SVC_VOLUME_MINIMUM_DECIBELS : decibels;
}

static inline Float32 SVCVolumeDecibelsToScalar(Float32 decibels) {
    if (isnan(decibels) || decibels <= SVC_VOLUME_MINIMUM_DECIBELS) {
        return 0.0f;
    }
    if (decibels >= SVC_VOLUME_MAXIMUM_DECIBELS) {
        return 1.0f;
    }
    return powf(10.0f, decibels / 40.0f);
}

static inline Float32 SVCVolumeScalarToGain(Float32 scalar) {
    scalar = SVCVolumeClampScalar(scalar);
    if (scalar == 0.0f) {
        return 0.0f;
    }
    return powf(10.0f, SVCVolumeScalarToDecibels(scalar) / 20.0f);
}

#endif
