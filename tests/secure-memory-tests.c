#include "SecureAudio.h"
#include <mach/mach_vm.h>
#include <assert.h>
#include <stdio.h>

int main(void) {
    mach_port_t port = MACH_PORT_NULL;
    SVCSharedAudio *writer = SVCAudioAllocate(&port);
    assert(writer != NULL && port != MACH_PORT_NULL);
    const SVCSharedAudio *reader = SVCAudioMapReadPort(port);
    assert(reader != NULL && reader != writer);
    float samples[] = {0.25f, -0.25f}, result[2];
    SVCSharedAudioStoreFrame(writer, 100, samples);
    assert(SVCSharedAudioLoadFrame(reader, 100, result));
    assert(result[0] == 0.25f && result[1] == -0.25f);
    assert(mach_vm_protect(mach_task_self(), (mach_vm_address_t)(uintptr_t)reader,
        SVCAudioAllocationSize(), FALSE, VM_PROT_READ | VM_PROT_WRITE) == KERN_PROTECTION_FAILURE);
    mach_vm_address_t illicit = 0;
    kern_return_t denied = mach_vm_map(mach_task_self(), &illicit, SVCAudioAllocationSize(), 0,
        VM_FLAGS_ANYWHERE, port, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE,
        VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    printf("Writable capability mapping denied with Mach status %d\n", denied);
    assert(denied == KERN_PROTECTION_FAILURE || denied == KERN_INVALID_RIGHT);
    mach_port_deallocate(mach_task_self(), port);
    SVCAudioDeallocate(reader);
    SVCAudioDeallocate(writer);
    puts("secure-memory-tests: PASS (anonymous transfer, kernel-enforced read-only capability)");
    return 0;
}
