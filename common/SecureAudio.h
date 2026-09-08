#ifndef SVC_SECURE_AUDIO_H
#define SVC_SECURE_AUDIO_H
#include "SharedAudio.h"
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>

#define SVC_BROKER_WRITER "org.soundvolumecontrol.broker.writer"
#define SVC_BROKER_READER "org.soundvolumecontrol.broker.reader"
#define SVC_BROKER_POLICY "/Library/Application Support/SoundVolumeControl/reader.requirement"
#define SVC_BROKER_BINARY "/Library/PrivilegedHelperTools/org.soundvolumecontrol.broker"
// HAL can host the plug-in in the separate .helper XPC executable.
// Keep each identity explicit and require Apple's signature for every branch.
#define SVC_DRIVER_REQUIREMENT "anchor apple and (identifier \"com.apple.audio.coreaudiod\" or identifier \"com.apple.audio.Core-Audio-Driver-Service\" or identifier \"com.apple.audio.Core-Audio-Driver-Service.helper\" or identifier \"com.apple.audio.DriverHelper\")"

// Anonymous memory. The exported capability has a READ-only maximum protection.
size_t SVCAudioAllocationSize(void);
SVCSharedAudio *SVCAudioAllocate(mach_port_t *readPort);
const SVCSharedAudio *SVCAudioMapReadPort(mach_port_t port);
void SVCAudioDeallocate(const SVCSharedAudio *audio);
char *SVCCopyBrokerRequirement(CFStringRef bundleIdentifier);

// Non-RT setup; callbacks only acquire/release an atomic mapping lease.
bool SVCWriterConnect(const char *service, const char *requirement, bool privileged);
SVCSharedAudio *SVCWriterAcquire(void);
void SVCWriterRelease(void);

typedef struct SVCReaderConnection SVCReaderConnection;
SVCReaderConnection *SVCReaderOpen(const char *service, const char *requirement,
                                  bool privileged, unsigned timeoutSeconds);
const SVCSharedAudio *SVCReaderAudio(SVCReaderConnection *reader);
bool SVCReaderIsAlive(SVCReaderConnection *reader);
void SVCReaderClose(SVCReaderConnection *reader);
#endif
