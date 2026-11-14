# Validation

The project is a development candidate. Automated checks cover algorithms,
authentication, packaging, and simulated lifecycle behavior. Installed audible
playback and reliability have not been accepted; use the
[manual checklist](manual-acceptance.md) to record those results.

## Automated coverage

Run `make check` on an Apple Silicon Mac with Command Line Tools. Tests use
isolated preferences, temporary files, and a temporary per-user launchd service;
they do not install the driver, change audio routes, or play audio.

| Area | Coverage |
| --- | --- |
| Driver | Output-only topology, volume/mute properties, stream state, final WriteMix publication. |
| Audio processing | Square-law gain, smoothing, underruns, gaps, frame integrity, and restart behavior. |
| App lifecycle | Readiness handshake, startup failure, stale helper messages, restoration decisions, and safe Quit. |
| Anonymous memory | Matching PCM across mappings; kernel rejection of write escalation. |
| XPC integration | Real driver-generated PCM between separate signed processes; exact reader/broker pins; wrong identities and roles denied. |
| Writer identity | Real Apple HAL helper accepted when present; unrelated Apple executable and ad-hoc identity impersonation denied. |
| Session ownership | Fresh rings after reconnect, frozen old mappings, inactive-user rejection, simulated revocation. |
| Legacy regression | Darwin POSIX shared-memory initialization and cross-process audio; fixtures are test-only. |
| Build | Property lists, strict signatures, and absence of production named-memory/capture APIs. |

The secure writer fixture invokes actual driver initialization and WriteMix,
using isolated service discovery and a test signature. This does not exercise
the installed HAL sandbox. Session changes are simulated through a test-only
command compiled out of production.

## Packaging

```sh
make dmg
sh packaging/audit-dmg.sh dist/SoundVolumeControl-0.8.7.dmg
```

The audit mounts the DMG read-only and expands the package. It checks the
payload against local binaries, versions, icon, scripts, signatures, and both
directions of the broker/helper signature pins. It does not run the installer.
Build products and machine-specific checksums are excluded from source control.

## Error 60 regression

Installed 0.8.0 logs showed the broker rejecting the Apple-signed
`com.apple.audio.Core-Audio-Driver-Service.helper` host. Its identifier was
missing from the allowlist, leaving the reader waiting for a memory grant until
ETIMEDOUT (60). Version 0.8.1 adds the exact helper identifier under the Apple
signing anchor. Tests verify the real helper is accepted and impersonation is
rejected. Actual playback after this correction still requires manual acceptance.

## Warcraft III legacy device query regression

On 2026-09-13, the installed Warcraft III 3.0.0.24268 executable's FMOD 4
backend was observed to call `AudioDeviceGetProperty(device, 0, false,
kAudioDevicePropertyNominalSampleRate, ...)` and return an initialization
error when that query fails. A standalone read-only reproduction against
Sound Volume returned 2003332927 (`who?`); the global-scope query on the same
device returned 48000 Hz successfully. The driver now also accepts output
scope for nominal sample rate. Its fixed rate and output-only topology remain.

The contract regression fails before the fix and checks property discovery,
size, reads, same-rate writes, and rejection of unsupported rates.
`make audio-route-verify` additionally exercises the actual legacy API through
the installed HAL. On 2026-09-13, installed 0.8.4 passed this check at 48000 Hz
and all read-only route checks. The user confirmed Warcraft III starts without
the reported error. Audible game playback remains unverified.
This addresses the reproduced query failure; it does not establish compatibility
with every game or audio engine. No game files or preferences are modified.

## Limits

No independent security audit is claimed. Root, kernel compromise, compromised
trusted HAL hosts, and compromised authorized helpers are outside the boundary.
Revocation stops future updates; previously delivered samples cannot be recalled.
Physical-device support, native controls, perceived volume, clicks, latency,
restoration, real user switching, sleep/wake, long-run drift, CPU, memory, and
energy use require installed measurements.

## Cold launch exceeding an attempt deadline (0.8.7)

The 2026-11-14 boot on macOS 27.2.1 (26B131) reproduced error 60 with matching
installed 0.8.6/build 18 components and a healthy driver connection. The driver
activated its writer
connection at 12:17:46.267; the helper activated its reader at 12:17:52.963.
The broker accepted the reader at 12:18:10.653, but completed reader
authentication only at 12:18:14.495 and writer authentication at 12:18:14.504.
The helper had already canceled its connection at 12:18:12.820 when its
20-second attempt expired. No writer invalidation occurred. A later brief
installed-helper run received its buffer immediately without replacing any
component, and made no route change or test tone.

This recurrence is a cold service-launch/authentication delay exceeding a fixed
deadline. The 0.8.6 writer-reconnect fix addresses a different boot failure and
cannot recover an app that has already disabled itself. Increasing the deadline
would only move the same failure threshold.

Version 0.8.7 retains bounded attempts and automatically replaces the helper
after a pre-readiness ETIMEDOUT/ECONNREFUSED, with backoff capped at 15 seconds.
The physical output is restored before another attempt. Disable, Quit, and
output changes invalidate scheduled retries. Restoration failures, explicit
denial, busy-reader errors, unsupported formats, and established-session loss
remain terminal. Exhausted ECONNRESET also remains terminal because XPC can
surface remote signature rejection that way.

The isolated XPC regression pauses broker listener activation, observes an
actual reader error 60, then releases startup and verifies real driver PCM and
read-only memory through a fresh reader and the same HAL writer process.
Mocked app tests cover automatic retries, late readiness, capped backoff, and
cancellation without changing real audio devices. A real reboot remains a
separate acceptance test.

The final `make dmg` (including `make check`) and DMG audit passed on
2026-11-14. The 0.8.7 DMG SHA-256 is
`9785dab21da407599024b2db3dc55bc5bec9eb6fd1f7bb963847542a9952198c`.

The matching update was installed on 2026-11-14 at 14:09. App, embedded helper,
and driver report 0.8.7/build 19; installed executable bytes match the audited
build, signatures pass, and read-only `audio-route-verify` passes.

An installed recovery test then restored the saved physical outputs, stopped
the app, and paused only its broker from 14:13:23 to 14:13:51 with automatic
cleanup/resumption. The reopened helper logged error 60 at 14:13:43.683;
the app scheduled its own retry at 14:13:43.698 and started a fresh helper at
14:13:44.811. A read-only check at 23 seconds confirmed neither default output
was Sound Volume. On broker resumption, the fresh reader authenticated and
received a buffer at 14:13:51.440; normal and system-sounds outputs then both
became Sound Volume automatically. The canceled old reader was rejected during
deferred signature validation; the new reader authenticated successfully.
No test tone was generated. This validates installed recovery beyond the
20-second deadline; actual reboot and audible playback remain unverified for
0.8.7.

## Intermittent startup correction (0.8.3)

A regression reproduced the old behavior: a rejected reader signature waited
for the deadline and returned ETIMEDOUT. Buffer opens now expect an XPC reply;
rejection returns an authentication error or connection reset, and an occupied
reader slot returns EBUSY. Both directions still enforce the same signature pins.
Pending grants are released on disconnect; asynchronous replies retain reader
state until completion even if the caller times out.

A six-second writer delay (longer than the old five-second deadline), cancellation
before writer arrival, reconnects, concurrent-reader rejection, and broker
restart all pass. Cold setup has a bounded 20-second budget, with a 25-second app
watchdog. The complete update was installed on 2026-09-12; live logs confirmed
writer authentication, reader authentication, and a buffer grant. Read-only
installed driver property checks passed. The user confirmed audible music and
two Disable/Enable cycles without errors; live logs recorded three successful
grants. A subsequent login and the broader hardware checklist remain unverified.

## Boot-time missing broker service (0.8.6)

On 2026-11-11 at 11:22:36, launchd rejected the installed HAL writer's
`org.soundvolumecontrol.broker.writer` lookup with error 3 (No such process).
The driver logged an invalid broker connection and never retried it. At
11:23:30 and 11:31:41 the broker authenticated readers with `writer available=0`;
both requests exhausted the 20-second deadline. This is a service-registration
race followed by a permanently stranded writer, not a reader signature failure.

The writer now replaces invalid connections after a one-second delay, always
applying the original broker signature requirement. Interrupted connections
retain the existing restart path. Tests start a real driver fixture before the
isolated broker is registered, wait for a confirmed invalidation, register the
broker, and verify real PCM and read-only memory through the same writer process.
The complete 0.8.6 update was installed on 2026-11-11. All three bundles
report 0.8.6/build 18; live logs confirm writer authentication at 11:45:00,
reader authentication with `writer available=1`, and a buffer grant at 11:45:02.
Read-only installed audio-route checks passed. Audible playback is unverified;
installed cold-boot acceptance still requires a reboot.
