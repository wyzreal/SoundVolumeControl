#ifndef SVC_STARTUP_TIMING_H
#define SVC_STARTUP_TIMING_H
// Bound each attempt, not the whole enable operation: cold launch includes
// system code-signature validation and can outlast this deadline. The app
// retries temporary pre-readiness failures with a fresh helper and backoff.
#define SVC_BUFFER_STARTUP_SECONDS 20
// Allow physical-output setup after the buffer handshake finishes.
#define SVC_APP_STARTUP_SECONDS 25
#endif
