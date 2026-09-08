#ifndef SVC_SHARED_AUDIO_TRANSPORT_H
#define SVC_SHARED_AUDIO_TRANSPORT_H

#include "SharedAudio.h"
#include <sys/types.h>

/* Non-real-time only. Failure returns NULL and preserves the underlying errno.
 * Opening an existing mapping never resizes it or erases its frames. */
SVCSharedAudio *SVCSharedAudioCreate(const char *name, mode_t mode);
const SVCSharedAudio *SVCSharedAudioMapReadOnly(const char *name);
void SVCSharedAudioUnmap(const SVCSharedAudio *audio);

#endif
