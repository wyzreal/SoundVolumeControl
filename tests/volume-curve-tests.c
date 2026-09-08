#include "VolumeCurve.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static int NearlyEqual(Float32 actual, Float32 expected, Float32 tolerance) {
    return fabsf(actual - expected) <= tolerance;
}

static void CheckPoint(Float32 scalar, Float32 decibels, Float32 gain) {
    assert(NearlyEqual(SVCVolumeScalarToDecibels(scalar), decibels, 0.001f));
    assert(NearlyEqual(SVCVolumeScalarToGain(scalar), gain, 0.00001f));
    if (scalar > 0.004f) {
        assert(NearlyEqual(SVCVolumeDecibelsToScalar(decibels),
                           scalar, 0.00001f));
    }
}

int main(void) {
    CheckPoint(0.0f, -96.0f, 0.0f);
    CheckPoint(0.10f, -40.0f, 0.01f);
    CheckPoint(0.25f, -24.0824f, 0.0625f);
    CheckPoint(0.50f, -12.0412f, 0.25f);
    CheckPoint(0.60f, -8.87395f, 0.36f);
    CheckPoint(0.75f, -4.99755f, 0.5625f);
    CheckPoint(1.0f, 0.0f, 1.0f);

    assert(SVCVolumeScalarToGain(-1.0f) == 0.0f);
    assert(SVCVolumeScalarToGain(NAN) == 0.0f);
    assert(SVCVolumeScalarToGain(INFINITY) == 0.0f);
    assert(SVCVolumeScalarToGain(2.0f) == 1.0f);
    assert(SVCVolumeDecibelsToScalar(-96.0f) == 0.0f);
    assert(SVCVolumeDecibelsToScalar(NAN) == 0.0f);
    assert(SVCVolumeDecibelsToScalar(INFINITY) == 1.0f);

    puts("PASS: shared square-law volume curve");
    return 0;
}
