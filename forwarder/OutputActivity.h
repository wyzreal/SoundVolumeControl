#ifndef SVC_OUTPUT_ACTIVITY_H
#define SVC_OUTPUT_ACTIVITY_H

#include <stdbool.h>
#include <stdint.h>

// Called on the control thread. Keep I/O warm across short pauses and resume
// immediately when a client starts, even before the first ring write.
static inline bool SVCPhysicalIOWanted(bool activityKnown, bool clientRunning,
                                       bool writerActive, uint64_t nowNanos,
                                       uint64_t *idleSince) {
    if (!activityKnown || clientRunning || writerActive) {
        *idleSince = 0;
        return true;
    }
    if (*idleSince == 0) *idleSince = nowNanos;
    return nowNanos - *idleSince < UINT64_C(2000000000);
}

#endif
