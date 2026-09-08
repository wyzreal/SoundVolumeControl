#include "SecureAudio.h"
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <errno.h>
#include <stdlib.h>

struct SVCReaderConnection {
    xpc_connection_t connection;
    dispatch_semaphore_t ready;
    _Atomic(bool) alive;
    const SVCSharedAudio *audio;
};
static void FinalizeReader(void *context) {
    SVCReaderConnection *reader = context;
    SVCAudioDeallocate(reader->audio);
    dispatch_release(reader->ready);
    free(reader);
}

SVCReaderConnection *SVCReaderOpen(const char *service, const char *requirement,
                                  bool privileged, unsigned timeoutSeconds) {
    SVCReaderConnection *reader = calloc(1, sizeof(*reader));
    if (reader == NULL) return NULL;
    atomic_init(&reader->alive, true);
    reader->ready = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create("org.soundvolumecontrol.reader", DISPATCH_QUEUE_SERIAL);
    reader->connection = xpc_connection_create_mach_service(service, queue,
        privileged ? XPC_CONNECTION_MACH_SERVICE_PRIVILEGED : 0);
    dispatch_release(queue);
    if (reader->connection == NULL) { FinalizeReader(reader); return NULL; }
    xpc_connection_set_context(reader->connection, reader);
    xpc_connection_set_finalizer_f(reader->connection, FinalizeReader);
    if (xpc_connection_set_peer_code_signing_requirement(reader->connection, requirement) != 0) {
        xpc_release(reader->connection);
        errno = EACCES;
        return NULL;
    }
    xpc_connection_set_event_handler(reader->connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            atomic_store(&reader->alive, false);
            dispatch_semaphore_signal(reader->ready);
            return;
        }
        if (xpc_get_type(event) != XPC_TYPE_DICTIONARY || reader->audio != NULL) return;
        const char *op = xpc_dictionary_get_string(event, "op");
        if (op == NULL || strcmp(op, "grant") != 0) return;
        mach_port_t port = xpc_dictionary_copy_mach_send(event, "memory");
        if (port != MACH_PORT_NULL) {
            reader->audio = SVCAudioMapReadPort(port);
            mach_port_deallocate(mach_task_self(), port);
        }
        if (reader->audio == NULL) atomic_store(&reader->alive, false);
        dispatch_semaphore_signal(reader->ready);
    });
    xpc_connection_activate(reader->connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "op", "open");
    xpc_connection_send_message(reader->connection, request);
    xpc_release(request);
    long timeout = dispatch_semaphore_wait(reader->ready,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutSeconds * NSEC_PER_SEC));
    if (timeout != 0 || !atomic_load(&reader->alive)) {
        SVCReaderClose(reader);
        errno = timeout != 0 ? ETIMEDOUT : EACCES;
        return NULL;
    }
    return reader;
}
const SVCSharedAudio *SVCReaderAudio(SVCReaderConnection *reader) { return reader->audio; }
bool SVCReaderIsAlive(SVCReaderConnection *reader) { return reader != NULL && atomic_load(&reader->alive); }
void SVCReaderClose(SVCReaderConnection *reader) {
    if (reader == NULL) return;
    xpc_connection_cancel(reader->connection);
    xpc_release(reader->connection);
}
