#include "SecureAudio.h"
#include "SoundVolumeControlIDs.h"
#include <assert.h>
#include <signal.h>
#include <unistd.h>

static const char *service, *requirement;
static volatile sig_atomic_t revokeRequested;
const char *SVCTestBrokerName(void) { return service; }
const char *SVCTestBrokerRequirement(void) { return requirement; }
extern void *SoundVolumeControl_Create(CFAllocatorRef, CFUUIDRef);
extern void SVCWriterTestRevoke(void);
static void RequestRevoke(int signal) { (void)signal; revokeRequested = 1; }

int main(int argc, char **argv) {
    assert(argc == 3);
    service = argv[1]; requirement = argv[2];
    alarm(40);
    signal(SIGUSR1, RequestRevoke);
    AudioServerPlugInHostInterface host = {0};
    AudioServerPlugInDriverRef driver = SoundVolumeControl_Create(NULL, kAudioServerPlugInTypeUUID);
    assert((*driver)->Initialize(driver, &host) == noErr);
    assert((*driver)->StartIO(driver, kSVCObjectDevice, 1) == noErr);
    Float32 samples[512 * 2];
    for (unsigned i = 0; i < 1024; ++i) samples[i] = i % 2 ? -0.25f : 0.25f;
    for (uint64_t cycle = 1; ; ++cycle) {
        AudioServerPlugInIOCycleInfo info = {0};
        info.mOutputTime.mSampleTime = (Float64)(cycle * 512);
        assert((*driver)->DoIOOperation(driver, kSVCObjectDevice, kSVCObjectOutputStream,
            1, kAudioServerPlugInIOOperationWriteMix, 512, &info, samples, NULL) == noErr);
        if (revokeRequested) { revokeRequested = 0; SVCWriterTestRevoke(); }
        usleep(10000);
    }
}
