#include "SharedAudioTransport.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static void *MapDescriptor(int descriptor, int protection) {
    struct stat information;
    if (fstat(descriptor, &information) != 0) return NULL;
    size_t pageSize = (size_t)getpagesize();
    size_t mappedSize = (sizeof(SVCSharedAudio) + pageSize - 1)
        / pageSize * pageSize;
    // Darwin reports the page-rounded allocation, not the requested length.
    if (information.st_size < (off_t)sizeof(SVCSharedAudio)
        || information.st_size > (off_t)mappedSize) {
        errno = EPROTO;
        return NULL;
    }
    void *mapping = mmap(NULL, sizeof(SVCSharedAudio), protection,
                         MAP_SHARED, descriptor, 0);
    return mapping == MAP_FAILED ? NULL : mapping;
}

SVCSharedAudio *SVCSharedAudioCreate(const char *name, mode_t mode) {
    bool created = true;
    int descriptor = shm_open(name, O_CREAT | O_EXCL | O_RDWR, mode);
    if (descriptor < 0 && errno == EEXIST) {
        created = false;
        descriptor = shm_open(name, O_RDWR, 0);
    }
    if (descriptor < 0) return NULL;
    (void)fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    struct stat information;
    SVCSharedAudio *audio = NULL;
    if (fstat(descriptor, &information) != 0) goto finish;
    if (information.st_uid != geteuid()
        || (information.st_mode & 0022) != 0) {
        errno = EACCES;
        goto finish;
    }
    // Darwin permits ftruncate only on a new, unsized shm object. fchmod is
    // unsupported for these descriptors; permissions come from shm_open.
    if (created && ftruncate(descriptor, sizeof(SVCSharedAudio)) != 0) {
        goto finish;
    }
    audio = MapDescriptor(descriptor, PROT_READ | PROT_WRITE);
    if (audio != NULL) {
        if (created) {
            SVCSharedAudioInitialize(audio, 48000);
        } else if (!SVCSharedAudioIsValid(audio)) {
            SVCSharedAudioUnmap(audio);
            audio = NULL;
            errno = EPROTO;
        }
    }
finish:;
    int savedError = errno;
    (void)close(descriptor);
    if (audio == NULL && created) (void)shm_unlink(name);
    errno = savedError;
    return audio;
}

const SVCSharedAudio *SVCSharedAudioMapReadOnly(const char *name) {
    int descriptor = shm_open(name, O_RDONLY, 0);
    if (descriptor < 0) return NULL;
    (void)fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    const SVCSharedAudio *audio = MapDescriptor(descriptor, PROT_READ);
    int savedError = errno;
    (void)close(descriptor);
    if (audio != NULL && !SVCSharedAudioIsValid(audio)) {
        SVCSharedAudioUnmap(audio);
        audio = NULL;
        savedError = EPROTO;
    }
    errno = savedError;
    return audio;
}

void SVCSharedAudioUnmap(const SVCSharedAudio *audio) {
    if (audio != NULL) (void)munmap((void *)audio, sizeof(*audio));
}
