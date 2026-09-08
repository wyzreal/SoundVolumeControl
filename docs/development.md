# Developer guide — 0.8.1

All app/helper/driver bundles are 0.8.1/build 13. Native arm64, macOS 14+,
system frameworks only. The fourth executable is a small XPC broker.

## Components

- driver/SoundVolumeControl.c: HAL topology, native controls, WriteMix publication.
- common/SharedAudio.h: atomic ring ABI v2.
- common/SecureAudioMemory.c: anonymous allocation and READ-only capabilities.
- common/SecureAudioWriter.c: driver connection, rotation, atomic mapping leases.
- common/SecureAudioReader.c: authenticated connection and reader lifetime.
- broker/main.c: writer/reader trust checks, console gating, revocation.
- forwarder/: physical output IO, sample reader, gain, cleanup.
- app/main.m: minimal menu, readiness, routing, and restoration.
- tools/signing-policy.c: exact signed-binary hash policy generation.

tests/legacy/SharedAudioTransport.c remains solely for historical POSIX regression tests.
It is not linked into production. Old shm names remain only for migration cleanup.

## Build and test

```sh
make check
make dmg
sh packaging/audit-dmg.sh dist/SoundVolumeControl-0.8.1.dmg
```

Targets: driver-test, processor-test, shared-reader-test, volume-curve-test,
app-test, ipc-test (historical POSIX), and secure-test (anonymous memory/XPC).

The secure test registers a random temporary per-user launchd service, starts
independently signed fixtures, tests access control, then unregisters and removes
its files. It requires permission outside restrictive agent sandboxes. It does
not install a driver, change audio settings, or play a tone.

The writer fixture invokes real driver initialization and WriteMix; only service
discovery is redirected. Tests cover correct PCM, signature and role rejection,
unsafe policy modes, read-only capability enforcement, new allocations on
reconnect, frozen old mappings, and console revocation. The session event is
simulated by a test-only command compiled out of production. This is not an
installed HAL sandbox or real fast-user-switch acceptance test.

Mocked app tests isolate preferences and check readiness, failure cleanup,
stale output rejection, and safe Quit without touching audio devices.

## Signing order

1. Build and hardened-runtime sign the broker.
2. Generate its hash requirement into driver/helper Info.plists.
3. Sign the driver and hardened-runtime helper; embed the helper and sign the app.
4. Generate the root-owned reader policy from the signed helper.
5. Package all matching parts together.

There is no circular binary-hash dependency. Never re-sign after generating
pins. The current build is ad-hoc signed. A notarized release needs Developer ID
signing and regeneration/retesting of every pin after final signing.

## Package lifecycle

The DMG installs:

- /Applications/SoundVolumeControl.app (includes forwarder)
- /Library/Audio/Plug-Ins/HAL/SoundVolumeControl.driver
- /Library/PrivilegedHelperTools/org.soundvolumecontrol.broker
- /Library/LaunchDaemons/org.soundvolumecontrol.broker.plist
- /Library/Application Support/SoundVolumeControl/reader.requirement

Preinstall quits the old app, refuses replacement while the virtual output
remains a default, and unloads the broker. Postinstall verifies signatures,
normalizes broker/policy ownership and modes, loads the broker, restarts Core
Audio, clears old public buffers, and opens the app as the console user.
An existing Start at Login preference is preserved.

The DMG uninstaller verifies restoration, unloads the broker, moves app/broker
files to Trash, removes the driver, and restarts Core Audio. Use the complete
DMG workflow to avoid mismatched identities and orphaned services.

## Installed validation

After manual installation, `make audio-route-verify` is read-only. Test music, native
keys/Control Center, 60%, mute, Disable, Quit, reopen, helper/broker failure,
user switching, display reconnect, sleep/wake, and sustained playback.

Optional audible diagnostic (only intentionally): quit the app, then run the
matching signed helper with --diagnose --always-active --test-tone --run-seconds 3.
It generates a one-second 440 Hz tone. Normal operation never generates a tone.
Only one reader is allowed, and mismatched helper builds are rejected.

See [architecture](architecture.md) and [validation coverage](validation.md).
Record installed results against the [manual acceptance checklist](manual-acceptance.md).
The fixed virtual format is 48 kHz stereo and the helper rejects a mismatched
physical nominal rate. Bounded clock-drift correction is not a general
sample-rate converter. Current CPU/RAM/energy and long-run performance remain
unmeasured; historical process-tap measurements do not describe this transport.

## App icon

The original transparent PNG and macOS ICNS live in `app/Assets`. Regenerate
the ICNS with `sh scripts/build-icon.sh`, then run `make menu-app` to embed it
and refresh the outer app signature. The menu-bar status symbol uses SF Symbols.
