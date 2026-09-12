#include "SecureAudio.h"
#include "StartupTiming.h"
#include "SharedAudioReader.h"
#include <assert.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>

int main(int argc, char **argv) {
    assert(argc == 4);
    alarm(35);
    bool denied = strcmp(argv[3], "deny") == 0;
    bool revoke = strcmp(argv[3], "revoke") == 0;
    bool timeout = strcmp(argv[3], "timeout") == 0;
    bool busy = strcmp(argv[3], "busy") == 0;
    bool hold = strcmp(argv[3], "hold") == 0;
    SVCReaderConnection *connection = SVCReaderOpen(argv[1], argv[2], false,
        timeout ? 1 : SVC_BUFFER_STARTUP_SECONDS);
    if (denied || timeout || busy) {
        assert(connection == NULL);
        assert(timeout ? errno == ETIMEDOUT : busy ? errno == EBUSY
               : errno == EACCES || errno == ECONNRESET);
        puts("reader expected failure: PASS"); return 0;
    }
    assert(connection != NULL);
    const SVCSharedAudio *audio = SVCReaderAudio(connection);
    for (unsigned i = 0; i < 100 && atomic_load(&audio->writeMixCount) < 5; ++i) usleep(10000);
    assert(atomic_load(&audio->writeMixCount) >= 5);
    SVCSharedAudioReader processor;
    SVCSharedAudioReaderInit(&processor, audio, 1024);
    float samples[256 * 2];
    assert(SVCSharedAudioReaderRead(&processor, samples, 256) == 256);
    for (unsigned i = 0; i < 512; ++i) assert(samples[i] == (i % 2 ? -0.25f : 0.25f));
    assert(mach_vm_protect(mach_task_self(), (mach_vm_address_t)(uintptr_t)audio,
        SVCAudioAllocationSize(), FALSE, VM_PROT_READ | VM_PROT_WRITE) == KERN_PROTECTION_FAILURE);
    if (hold) { puts("READY"); fflush(stdout); for (;;) pause(); }
    if (revoke) {
        puts("READY"); fflush(stdout);
        for (unsigned i = 0; i < 500 && SVCReaderIsAlive(connection); ++i) usleep(10000);
        assert(!SVCReaderIsAlive(connection));
        usleep(100000);
        uint64_t last = atomic_load(&audio->writeFrame);
        usleep(100000);
        assert(atomic_load(&audio->writeFrame) == last);
        assert(atomic_load(&audio->writerActive) == 0);
    } else {
        for (unsigned rotation = 0; rotation < 3; ++rotation) {
            mach_vm_address_t duplicate = 0;
            vm_prot_t current = 0, maximum = 0;
            assert(mach_vm_remap(mach_task_self(), &duplicate, SVCAudioAllocationSize(),
                0, VM_FLAGS_ANYWHERE, mach_task_self(), (mach_vm_address_t)(uintptr_t)audio,
                FALSE, &current, &maximum, VM_INHERIT_NONE) == KERN_SUCCESS);
            assert((maximum & VM_PROT_WRITE) == 0);
            const SVCSharedAudio *old = (const SVCSharedAudio *)(uintptr_t)duplicate;
            SVCReaderClose(connection);
            usleep(150000);
            uint64_t last = atomic_load(&old->writeFrame);
            assert(atomic_load(&old->writerActive) == 0);
            connection = SVCReaderOpen(argv[1], argv[2], false, 5);
            assert(connection != NULL);
            audio = SVCReaderAudio(connection);
            usleep(100000);
            assert(atomic_load(&audio->writeFrame) > last);
            assert(atomic_load(&old->writeFrame) == last);
            float stale[2];
            assert(!SVCSharedAudioLoadFrame(audio, last - 1, stale));
            SVCAudioDeallocate(old);
        }
    }
    SVCReaderClose(connection);
    puts("secure-reader-test: PASS (real driver output, read-only, session lease)");
    return 0;
}
