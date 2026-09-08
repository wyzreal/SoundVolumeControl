#include "SecureAudio.h"
#include <errno.h>
#include <mach/mach_vm.h>
#include <stdlib.h>

size_t SVCAudioAllocationSize(void) {
    return (sizeof(SVCSharedAudio) + vm_page_size - 1) / vm_page_size * vm_page_size;
}

SVCSharedAudio *SVCAudioAllocate(mach_port_t *readPort) {
    *readPort = MACH_PORT_NULL;
    mach_vm_address_t address = 0;
    mach_vm_size_t size = SVCAudioAllocationSize();
    if (mach_vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE)
        != KERN_SUCCESS) return NULL;
    memory_object_size_t length = size;
    if (mach_make_memory_entry_64(mach_task_self(), &length, address,
                                  VM_PROT_READ, readPort, MACH_PORT_NULL)
        != KERN_SUCCESS || length != size) {
        if (*readPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), *readPort);
        mach_vm_deallocate(mach_task_self(), address, size);
        return NULL;
    }
    SVCSharedAudio *audio = (SVCSharedAudio *)(uintptr_t)address;
    SVCSharedAudioInitialize(audio, 48000);
    return audio;
}

const SVCSharedAudio *SVCAudioMapReadPort(mach_port_t port) {
    mach_vm_address_t address = 0;
    if (mach_vm_map(mach_task_self(), &address, SVCAudioAllocationSize(), 0,
                    VM_FLAGS_ANYWHERE, port, 0, FALSE, VM_PROT_READ,
                    VM_PROT_READ, VM_INHERIT_NONE) != KERN_SUCCESS) return NULL;
    const SVCSharedAudio *audio = (const SVCSharedAudio *)(uintptr_t)address;
    if (!SVCSharedAudioIsValid(audio)) {
        SVCAudioDeallocate(audio);
        return NULL;
    }
    return audio;
}

void SVCAudioDeallocate(const SVCSharedAudio *audio) {
    if (audio != NULL) mach_vm_deallocate(mach_task_self(),
        (mach_vm_address_t)(uintptr_t)audio, SVCAudioAllocationSize());
}

char *SVCCopyBrokerRequirement(CFStringRef bundleIdentifier) {
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(bundleIdentifier);
    if (bundle == NULL) return NULL;
    CFTypeRef value = CFBundleGetValueForInfoDictionaryKey(bundle,
                                                         CFSTR("SVCBrokerRequirement"));
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) return NULL;
    char buffer[256];
    if (!CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) return NULL;
    // A build-specific hash, never an identifier-only requirement.
    if (strncmp(buffer, "cdhash H\"", 9) != 0) return NULL;
    return strdup(buffer);
}
