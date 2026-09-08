#include "SecureAudio.h"
#include <SystemConfiguration/SystemConfiguration.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

// All broker state is confined to one serial queue. No PCM is mapped here.
static dispatch_queue_t queue;
static xpc_connection_t writer, reader;
static uint64_t generation;
static bool opened;
static SCDynamicStoreRef sessionStore;
#ifdef SVC_BROKER_TESTING
static uid_t testConsoleUID;
#endif

static uid_t ConsoleUID(void) {
#ifdef SVC_BROKER_TESTING
    return testConsoleUID;
#else
    uid_t uid = (uid_t)-1;
    CFStringRef name = SCDynamicStoreCopyConsoleUser(NULL, &uid, NULL);
    if (name != NULL) CFRelease(name);
    return uid;
#endif
}

static void Rotate(bool enabled) {
    ++generation;
    if (writer == NULL) return;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "op", "rotate");
    xpc_dictionary_set_uint64(message, "generation", generation);
    xpc_dictionary_set_bool(message, "enabled", enabled);
    xpc_connection_send_message(writer, message);
    xpc_release(message);
}

static void DropReader(void) {
    if (reader != NULL) {
        xpc_connection_cancel(reader);
        xpc_release(reader);
        reader = NULL;
    }
    opened = false;
    Rotate(false);
}

static void SessionChanged(SCDynamicStoreRef store, CFArrayRef keys, void *context) {
    (void)store; (void)keys; (void)context;
    // Also rotate when the UID is unchanged: never reuse a prior login lease.
    DropReader();
}

static char *ReadPolicy(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat info = {0};
#ifdef SVC_BROKER_TESTING
    uid_t owner = getuid();
#else
    uid_t owner = 0;
#endif
    char buffer[256] = {0};
    bool valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode)
        && info.st_uid == owner && (info.st_mode & 0022) == 0
        && info.st_size > 0 && info.st_size < (off_t)sizeof(buffer);
    ssize_t count = valid ? read(fd, buffer, sizeof(buffer) - 1) : -1;
    close(fd);
    if (count != info.st_size || count < 0) return NULL;
    // Pin an exact signed build, not a forgeable ad-hoc signing identifier.
    if (count != 50 || strncmp(buffer, "cdhash H\"", 9) != 0 || buffer[49] != '"') return NULL;
    for (size_t i = 9; i < 49; ++i) {
        if (!((buffer[i] >= '0' && buffer[i] <= '9') ||
              (buffer[i] >= 'a' && buffer[i] <= 'f'))) return NULL;
    }
    return strdup(buffer);
}

static xpc_connection_t Listen(const char *name, const char *requirement, bool isWriter) {
    xpc_connection_t listener = xpc_connection_create_mach_service(name, queue,
        XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (listener == NULL) return NULL;
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        xpc_connection_set_target_queue(peer, queue);
        if (xpc_connection_set_peer_code_signing_requirement(peer, requirement) != 0) {
            xpc_connection_cancel(peer);
            return;
        }
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                if (peer == reader) DropReader();
                if (peer == writer) {
                    xpc_release(writer);
                    writer = NULL;
                    DropReader();
                }
                return;
            }
            if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) { xpc_connection_cancel(peer); return; }
            const char *op = xpc_dictionary_get_string(event, "op");
            if (op == NULL) { xpc_connection_cancel(peer); return; }
#ifdef SVC_BROKER_TESTING
            if (isWriter && peer == writer && strcmp(op, "test-revoke") == 0) {
                testConsoleUID = (uid_t)-1;
                DropReader();
                return;
            }
#endif
            if (isWriter && strcmp(op, "hello") == 0) {
                if (writer != NULL && writer != peer) { xpc_connection_cancel(peer); return; }
                if (writer == NULL) { writer = peer; xpc_retain(writer); }
                Rotate(reader != NULL && opened);
            } else if (isWriter && peer == writer && strcmp(op, "publish") == 0) {
                if (reader == NULL || !opened || xpc_dictionary_get_uint64(event, "generation") != generation) return;
                if (xpc_connection_get_euid(reader) != ConsoleUID()) { DropReader(); return; }
                mach_port_t port = xpc_dictionary_copy_mach_send(event, "memory");
                if (port == MACH_PORT_NULL) { DropReader(); return; }
                xpc_object_t grant = xpc_dictionary_create(NULL, NULL, 0);
                xpc_dictionary_set_string(grant, "op", "grant");
                xpc_dictionary_set_mach_send(grant, "memory", port);
                xpc_connection_send_message(reader, grant);
                mach_port_deallocate(mach_task_self(), port);
                xpc_release(grant);
            } else if (!isWriter && strcmp(op, "open") == 0) {
                uid_t uid = xpc_connection_get_euid(peer);
                if (uid == 0 || uid == (uid_t)-1 || uid != ConsoleUID() || reader != NULL) {
                    xpc_connection_cancel(peer);
                    return;
                }
                reader = peer;
                xpc_retain(reader);
                opened = true;
                Rotate(true);
            } else {
                xpc_connection_cancel(peer);
            }
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    return listener;
}

int main(int argc, char **argv) {
    const char *writerName = SVC_BROKER_WRITER, *readerName = SVC_BROKER_READER;
    const char *writerRequirement = SVC_DRIVER_REQUIREMENT;
    const char *policy = SVC_BROKER_POLICY;
#ifdef SVC_BROKER_TESTING
    if (argc != 6) return 64;
    writerName = argv[1]; readerName = argv[2]; policy = argv[3];
    writerRequirement = argv[4]; testConsoleUID = (uid_t)strtoul(argv[5], NULL, 10);
#else
    (void)argv;
    if (argc != 1 || geteuid() != 0) return 64;
#endif
    char *readerRequirement = ReadPolicy(policy);
    if (readerRequirement == NULL) { fputs("broker: invalid reader policy\n", stderr); return 1; }
    queue = dispatch_queue_create("org.soundvolumecontrol.broker", DISPATCH_QUEUE_SERIAL);
    if (Listen(writerName, writerRequirement, true) == NULL ||
        Listen(readerName, readerRequirement, false) == NULL) return 1;
    sessionStore = SCDynamicStoreCreate(NULL, CFSTR("SoundVolumeControl broker"), SessionChanged, NULL);
    const void *key = CFSTR("State:/Users/ConsoleUser");
    CFArrayRef keys = CFArrayCreate(NULL, &key, 1, &kCFTypeArrayCallBacks);
    if (sessionStore == NULL || !SCDynamicStoreSetNotificationKeys(sessionStore, keys, NULL) ||
        !SCDynamicStoreSetDispatchQueue(sessionStore, queue)) return 1;
    CFRelease(keys);
    dispatch_main();
}
