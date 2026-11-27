#ifndef SVC_FORWARDER_STATUS_H
#define SVC_FORWARDER_STATUS_H

// In app mode stdout carries one UTF-8 JSON object per line. Human-readable
// diagnostics (including arbitrary device names) go to stderr.
#define SVC_STATUS_OPTION "--status-json"
#define SVC_STATUS_READY @"ready"
#define SVC_STATUS_ACTIVE @"active"
#define SVC_STATUS_DESELECTED @"deselected"
#define SVC_STATUS_ERROR @"error"

#endif
