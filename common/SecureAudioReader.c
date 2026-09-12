#include "SecureAudio.h"
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <errno.h>
#include <stdlib.h>

struct SVCReaderConnection {
    xpc_connection_t connection;
    dispatch_semaphore_t ready;
    _Atomic(unsigned) references;
    _Atomic(bool) alive, closed;
    _Atomic(int) error;
    const SVCSharedAudio *audio;
};
static void ReleaseReader(void *context) {
    SVCReaderConnection *reader = context;
    if (atomic_fetch_sub(&reader->references, 1) != 1) return;
    SVCAudioDeallocate(reader->audio);
    dispatch_release(reader->ready);
    free(reader);
}
static void FailReader(SVCReaderConnection *reader, int error) {
    int expected = 0;
    atomic_compare_exchange_strong(&reader->error, &expected, error);
    atomic_store(&reader->alive, false);
    dispatch_semaphore_signal(reader->ready);
}
static int ConnectionError(xpc_object_t event) {
    return event == XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT ? EACCES : ECONNRESET;
}

SVCReaderConnection *SVCReaderOpen(const char *service, const char *requirement,
                                  bool privileged, unsigned timeoutSeconds) {
    SVCReaderConnection *reader = calloc(1, sizeof(*reader));
    if (reader == NULL) return NULL;
    atomic_init(&reader->references, 1); // Owned by the connection finalizer.
    atomic_init(&reader->alive, true);
    atomic_init(&reader->closed, false);
    atomic_init(&reader->error, 0);
    reader->ready = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create("org.soundvolumecontrol.reader", DISPATCH_QUEUE_SERIAL);
    reader->connection = xpc_connection_create_mach_service(service, queue,
        privileged ? XPC_CONNECTION_MACH_SERVICE_PRIVILEGED : 0);
    if (reader->connection == NULL) {
        dispatch_release(queue); ReleaseReader(reader); errno = ECONNREFUSED; return NULL;
    }
    xpc_connection_set_context(reader->connection, reader);
    xpc_connection_set_finalizer_f(reader->connection, ReleaseReader);
    if (xpc_connection_set_peer_code_signing_requirement(reader->connection, requirement) != 0) {
        dispatch_release(queue);
        xpc_release(reader->connection);
        errno = EACCES;
        return NULL;
    }
    xpc_connection_set_event_handler(reader->connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR && !atomic_load(&reader->closed)) {
            FailReader(reader, ConnectionError(event));
        }
    });
    xpc_connection_activate(reader->connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "op", "open");
    // A one-way request silently disappears when XPC rejects its signature.
    // A reply handler receives the explicit code-signing error instead.
    atomic_fetch_add(&reader->references, 1); // Reply may outlive cancellation.
    xpc_connection_send_message_with_reply(reader->connection, request, queue, ^(xpc_object_t reply) {
        if (!atomic_load(&reader->closed) && atomic_load(&reader->alive)) {
            if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
                FailReader(reader, ConnectionError(reply));
            } else if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
                FailReader(reader, EPROTO);
            } else {
                const char *op = xpc_dictionary_get_string(reply, "op");
                int64_t error = xpc_dictionary_get_int64(reply, "error");
                if (op != NULL && strcmp(op, "error") == 0) {
                    FailReader(reader, error == EBUSY ? EBUSY : EACCES);
                } else if (op == NULL || strcmp(op, "grant") != 0) {
                    FailReader(reader, EPROTO);
                } else {
                    mach_port_t port = xpc_dictionary_copy_mach_send(reply, "memory");
                    if (port != MACH_PORT_NULL) {
                        reader->audio = SVCAudioMapReadPort(port);
                        mach_port_deallocate(mach_task_self(), port);
                    }
                    if (reader->audio == NULL) FailReader(reader, EPROTO);
                    else dispatch_semaphore_signal(reader->ready);
                }
            }
        }
        ReleaseReader(reader);
    });
    dispatch_release(queue);
    xpc_release(request);
    long timeout = dispatch_semaphore_wait(reader->ready,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutSeconds * NSEC_PER_SEC));
    if (timeout != 0 || !atomic_load(&reader->alive)) {
        int error = timeout != 0 ? ETIMEDOUT : atomic_load(&reader->error);
        SVCReaderClose(reader);
        errno = error;
        return NULL;
    }
    return reader;
}
const SVCSharedAudio *SVCReaderAudio(SVCReaderConnection *reader) { return reader->audio; }
bool SVCReaderIsAlive(SVCReaderConnection *reader) { return reader != NULL && atomic_load(&reader->alive); }
void SVCReaderClose(SVCReaderConnection *reader) {
    if (reader == NULL) return;
    atomic_store(&reader->closed, true);
    atomic_store(&reader->alive, false);
    xpc_connection_cancel(reader->connection);
    xpc_release(reader->connection);
}
