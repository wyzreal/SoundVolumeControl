# Architecture: output-only audio with authenticated IPC

Current architecture for 0.8.2. Development candidate, not an independently
audited or hardware-validated release.

## Audio and control paths

The output-only HAL driver exposes native volume/mute and one 48 kHz stereo
stream, with zero input channels. It publishes final WriteMix samples to an
anonymous 32,768-frame ring. ProcessOutput is diagnostic-only.

The native helper maps the ring read-only, applies square-law gain with a
5 ms ramp and bounded clock correction, then renders to the physical output.
It disables all input streams on its physical IOProc first. There is no virtual
input, AVFoundation, ScreenCaptureKit, process tap, or recording API.

The small root-owned XPC broker only authorizes connections and passes memory
handles. It never maps PCM, renders audio, polls samples, or writes audio files.
Apple permits HAL plug-ins to contact services declared in
AudioServerPlugIn_MachServices; the driver declares only our writer endpoint.
See [Apple QA1811](https://developer.apple.com/library/archive/qa/qa1811/_index.html).

## Authentication

Distinct writer and reader endpoints enforce distinct roles using
xpc_connection_set_peer_code_signing_requirement before accepting messages.
The API checks received messages, avoiding PID-based identity lookup races.

- Writer: Apple signing anchor plus one of the observed Core Audio host
  identifiers: com.apple.audio.coreaudiod,
  com.apple.audio.Core-Audio-Driver-Service,
  com.apple.audio.Core-Audio-Driver-Service.helper, or com.apple.audio.DriverHelper.
- Reader: exact helper code-directory hash and the active console UID; root,
  unknown users, inactive users, and additional readers are rejected.
- Broker: clients pin its exact signed hash and use the privileged system
  service namespace, not a user-created lookalike.

The build generates hashes through Security.framework. Broker pins go into the
signed driver/helper Info.plists; the helper pin goes into a root-owned policy
file that rejects group/world write permission and final-component symlinks.
Identifier-only checks are insufficient for ad-hoc builds. Helper and broker
are hardened-runtime signed without debugging/injection entitlements.

Reference: [Apple peer signing requirements](https://developer.apple.com/documentation/xpc/xpc_connection_set_peer_code_signing_requirement(_:_:)).
The implementation also uses the local SDK's XPC and Mach memory contracts.

## Memory ownership and revocation

An authorized reader causes the driver to allocate a fresh anonymous ring.
The driver retains a writable mapping but exports only a memory-entry capability
with READ maximum permission. The broker forwards that capability without
mapping it. The kernel rejects writable mappings or permission escalation.

The broker tags rotations with generations and discards stale publications.
Reader disconnect, writer loss, and console-session changes revoke the lease.
The next reader gets a new allocation. Old mappings can retain previously
authorized samples but stop receiving subsequent audio.

Driver callbacks take lock-free atomic mapping leases. A control queue swaps
rings and deallocates retired mappings only after all callbacks have released
their leases. No allocation, XPC, locks, or deallocation occurs in audio callbacks.

## Scope and lifecycle

This protects against unrelated unprivileged processes, forged identities,
and stale readers. It does not protect against root, a compromised kernel,
a compromised trusted Core Audio host, or a compromised authorized helper.
Already delivered audio cannot be recalled. No independent audit is claimed.

Enable waits for mapping and physical-output readiness before selecting Sound
Volume. Startup times out after eight seconds. Disable and Quit restore only
selectors still pointing to Sound Volume, preserving external user changes.
Normal Quit is cancelled if restoration fails. Broker/helper loss prompts
restoration through supervision.

[Validation coverage](validation.md) records automated evidence. Real HAL
sandbox registration, music, privacy prompts, native controls, restoration,
sleep/wake, device changes, and sustained playback remain manual gates.
