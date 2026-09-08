#include "SoundVolumeControlIDs.h"
#include "SharedAudioTransport.h"
#include "SharedAudioReader.h"
#include "AudioProcessor.h"
#include "VolumeCurve.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern void *SoundVolumeControl_Create(CFAllocatorRef, CFUUIDRef);
static char sharedName[32];
const char *SVCDriverIPCName(void) { return sharedName; }

static void RemoveTestBuffer(void) {
    if (sharedName[0] != '\0') (void)shm_unlink(sharedName);
}

static int RunReader(const char *name) {
    const SVCSharedAudio *audio = SVCSharedAudioMapReadOnly(name);
    assert(audio != NULL);
    SVCSharedAudioReader reader;
    SVCSharedAudioReaderInit(&reader, audio, 1024);
    SVCGainProcessor gain;
    SVCGainProcessorInit(&gain, SVCVolumeScalarToGain(0.6f), 48000, 0);
    uint32_t total = 0;
    unsigned char command;
    while (read(STDIN_FILENO, &command, 1) == 1) {
        float source[512 * 2];
        float output[512 * 2];
        uint32_t rendered = SVCSharedAudioReaderRead(&reader, source, 512);
        AudioBufferList inputList = {1, {{2, sizeof(source), source}}};
        AudioBufferList outputList = {1, {{2, sizeof(output), output}}};
        SVCGainProcessorProcess(&gain, &inputList, &outputList);
        for (size_t index = 0; index < 1024; ++index) {
            float expected = rendered == 0 ? 0 : (index % 2 == 0 ? 0.09f : -0.09f);
            assert(fabsf(output[index] - expected) < 0.000001f);
        }
        total += rendered;
        if (command == 's') {
            assert(rendered == 0);
            assert(total > 100000);
        }
        assert(write(STDOUT_FILENO, &command, 1) == 1);
        if (command == 's') break;
    }
    SVCSharedAudioUnmap(audio);
    return 0;
}

static void TestRejectsWrongSize(void) {
    char name[32];
    snprintf(name, sizeof(name), "/svc-bad-%d", getpid());
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    assert(fd >= 0);
    assert(ftruncate(fd, 4096) == 0);
    assert(SVCSharedAudioCreate(name, 0600) == NULL);
    assert(errno == EPROTO);
    assert(SVCSharedAudioMapReadOnly(name) == NULL);
    struct stat information;
    assert(fstat(fd, &information) == 0);
    assert(information.st_size >= 4096);
    assert(information.st_size < (off_t)sizeof(SVCSharedAudio));
    close(fd);
    assert(shm_unlink(name) == 0);
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--reader") == 0) return RunReader(argv[2]);
    assert(argc == 1);
    alarm(20);
    snprintf(sharedName, sizeof(sharedName), "/svc-ipc-%d", getpid());
    atexit(RemoveTestBuffer);
    // Preserve the old POSIX initialization regression with a pre-existing, sized
    // object. The old unconditional fchmod/ftruncate fails here on macOS.
    SVCSharedAudio *initial = SVCSharedAudioCreate(sharedName, 0600);
    if (initial == NULL) {
        fprintf(stderr, "IPC test needs POSIX shared-memory access: %s\n", strerror(errno));
        return 1;
    }
    SVCSharedAudioUnmap(initial);
    AudioServerPlugInHostInterface host = {0};
    AudioServerPlugInDriverRef driver = SoundVolumeControl_Create(NULL,
        kAudioServerPlugInTypeUUID);
    assert(driver != NULL);
    assert((*driver)->Initialize(driver, &host) == noErr);
    assert((*driver)->StartIO(driver, kSVCObjectDevice, 1) == noErr);

    int commands[2], replies[2];
    assert(pipe(commands) == 0 && pipe(replies) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(commands[1]);
        close(replies[0]);
        assert(dup2(commands[0], STDIN_FILENO) >= 0);
        assert(dup2(replies[1], STDOUT_FILENO) >= 0);
        close(commands[0]);
        close(replies[1]);
        execl(argv[0], argv[0], "--reader", sharedName, NULL);
        _exit(127);
    }
    close(commands[0]);
    close(replies[1]);
    Float32 samples[512 * 2];
    for (size_t index = 0; index < 1024; ++index) samples[index] = index % 2 ? -0.25f : 0.25f;
    for (UInt32 cycle = 0; cycle < 256; ++cycle) {
        AudioServerPlugInIOCycleInfo info = {0};
        info.mOutputTime.mSampleTime = 8192 + cycle * 512;
        assert((*driver)->DoIOOperation(driver, kSVCObjectDevice,
            kSVCObjectOutputStream, 1, kAudioServerPlugInIOOperationWriteMix,
            512, &info, samples, NULL) == noErr);
        if (cycle == 10) assert((*driver)->Initialize(driver, &host) == noErr);
        unsigned char command = 'r', reply = 0;
        assert(write(commands[1], &command, 1) == 1);
        assert(read(replies[0], &reply, 1) == 1 && reply == command);
    }
    assert((*driver)->StopIO(driver, kSVCObjectDevice, 1) == noErr);
    unsigned char command = 's', reply = 0;
    assert(write(commands[1], &command, 1) == 1);
    assert(read(replies[0], &reply, 1) == 1 && reply == command);
    close(commands[1]);
    close(replies[0]);
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    TestRejectsWrongSize();
    puts("audio-ipc-tests: PASS (legacy POSIX initialization, separate reader process, wraparound, 60% gain, stop)");
    return 0;
}
