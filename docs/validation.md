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
sh packaging/audit-dmg.sh dist/SoundVolumeControl-0.8.1.dmg
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

## Limits

No independent security audit is claimed. Root, kernel compromise, compromised
trusted HAL hosts, and compromised authorized helpers are outside the boundary.
Revocation stops future updates; previously delivered samples cannot be recalled.
Physical-device support, native controls, perceived volume, clicks, latency,
restoration, real user switching, sleep/wake, long-run drift, CPU, memory, and
energy use require installed measurements.
