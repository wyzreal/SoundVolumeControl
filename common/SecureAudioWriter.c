#include "SecureAudio.h"
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <stdlib.h>
#include <os/log.h>

static _Atomic(SVCSharedAudio *) currentAudio;
static _Atomic(unsigned) leases;
static dispatch_queue_t writerQueue;
static xpc_connection_t writerConnection;
static char *writerService, *writerRequirement;
static bool writerPrivileged;
#ifdef SVC_SECURE_IPC_TESTING
static _Atomic(unsigned) invalidations;
unsigned SVCWriterTestInvalidations(void) { return atomic_load(&invalidations); }
#endif

SVCSharedAudio *SVCWriterAcquire(void) {
    atomic_fetch_add(&leases, 1);
    return atomic_load(&currentAudio);
}
void SVCWriterRelease(void) { atomic_fetch_sub(&leases, 1); }

// Runs on the control queue, never on a HAL render thread. Sequentially
// consistent leases prevent deallocation while a callback holds the old ring.
static void Retire(SVCSharedAudio *audio) {
    if (audio == NULL) return;
    if (atomic_load(&leases) == 0) {
        atomic_store(&audio->writerActive, 0);
        SVCAudioDeallocate(audio);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC),
                       writerQueue, ^{ Retire(audio); });
    }
}

static void Hello(void) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "op", "hello");
    xpc_connection_send_message(writerConnection, message);
    xpc_release(message);
}

#ifdef SVC_SECURE_IPC_TESTING
void SVCWriterTestRevoke(void) {
    dispatch_async(writerQueue, ^{
        if (writerConnection == NULL) return;
        xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(event, "op", "test-revoke");
        xpc_connection_send_message(writerConnection, event);
        xpc_release(event);
    });
}
#endif

static bool ConnectWriter(void);

static void RetryWriter(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), writerQueue, ^{
        if (!ConnectWriter()) RetryWriter();
    });
}

// A connection invalidated before launchd registers the service cannot be reused.
// All retries keep the original broker pin and run off the HAL render thread.
static bool ConnectWriter(void) {
    xpc_connection_t connection = xpc_connection_create_mach_service(writerService, writerQueue,
        writerPrivileged ? XPC_CONNECTION_MACH_SERVICE_PRIVILEGED : 0);
    writerConnection = connection;
    if (writerConnection == NULL) return false;
    if (xpc_connection_set_peer_code_signing_requirement(writerConnection, writerRequirement) != 0) {
        xpc_release(writerConnection);
        writerConnection = NULL;
        return false;
    }
    xpc_connection_set_event_handler(writerConnection, ^(xpc_object_t event) {
        if (connection != writerConnection) return;
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            Retire(atomic_exchange(&currentAudio, NULL));
            if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), writerQueue, ^{
                    if (connection == writerConnection) Hello();
                });
            } else {
                os_log_error(OS_LOG_DEFAULT, "SoundVolumeControl broker connection rejected or invalid; retrying with fresh authentication");
#ifdef SVC_SECURE_IPC_TESTING
                atomic_fetch_add(&invalidations, 1);
#endif
                writerConnection = NULL;
                xpc_connection_cancel(connection);
                xpc_release(connection);
                RetryWriter();
            }
            return;
        }
        if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
        const char *op = xpc_dictionary_get_string(event, "op");
        if (op == NULL || strcmp(op, "rotate") != 0) return;
        uint64_t generation = xpc_dictionary_get_uint64(event, "generation");
        bool enabled = xpc_dictionary_get_bool(event, "enabled");
        mach_port_t port = MACH_PORT_NULL;
        SVCSharedAudio *fresh = enabled ? SVCAudioAllocate(&port) : NULL;
        Retire(atomic_exchange(&currentAudio, fresh));
        if (!enabled) return;
        xpc_object_t reply = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(reply, "op", "publish");
        xpc_dictionary_set_uint64(reply, "generation", generation);
        if (fresh != NULL) xpc_dictionary_set_mach_send(reply, "memory", port);
        xpc_connection_send_message(writerConnection, reply);
        xpc_release(reply);
        if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
    });
    xpc_connection_activate(writerConnection);
    Hello();
    return true;
}

bool SVCWriterConnect(const char *service, const char *requirement, bool privileged) {
    if (writerQueue != NULL) return true;
    writerService = strdup(service);
    writerRequirement = strdup(requirement);
    if (writerService == NULL || writerRequirement == NULL) {
        free(writerService); free(writerRequirement);
        writerService = writerRequirement = NULL;
        return false;
    }
    writerPrivileged = privileged;
    writerQueue = dispatch_queue_create("org.soundvolumecontrol.writer", DISPATCH_QUEUE_SERIAL);
    dispatch_async(writerQueue, ^{ if (!ConnectWriter()) RetryWriter(); });
    return true;
}
