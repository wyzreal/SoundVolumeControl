# Manual acceptance — 0.9.1 candidate

## Historical verification

On 2026-11-22, the 0.8.9/build 21 package passed the full automated suite and
DMG audit. The installed components matched the audited build, the app was
running, and read-only Core Audio checks passed. The live update client offered
0.8.9 to a 0.8.8 version input and reported 0.8.9 as current. Audible playback
and hardware recovery were pending for that build. See [validation](validation.md).

On 2026-11-19, installed 0.8.8 components reported build 20 and matched the
audited package. Signatures, reader policy, and read-only audio checks passed.
The app and helper ran with forwarding enabled. Automated lifecycle tests
covered output-switch ordering and preserved Disable intent in that version.

0.8.7 installed partial pass on 2026-11-14: all components report build 19,
signatures and installed read-only audio checks pass. A controlled 28-second
broker delay reproduced error 60 at 20 seconds; the app retried automatically,
kept the physical outputs selected during the delay, and enabled both Sound
Volume defaults after the broker resumed. No test tone was generated. Audible
playback and an actual reboot still need acceptance. See the
[dated evidence](validation.md).

The earlier 2026-11-14 boot failed on 0.8.6: the helper timed out before macOS
finished launching/authenticating the broker. The deterministic isolated XPC
regression and installed delay test now cover that failure sequence.

0.8.6 installed partial pass on 2026-11-11: the full package upgraded
successfully; app/helper/driver report 0.8.6/build 18. Live logs at 11:45:00–02
confirm writer authentication, reader authentication with writer available,
and a buffer grant. Read-only `audio-route-verify` passed. Audible playback
and installed cold-boot/login recovery remain **not yet tested**.

Cold-start service-registration recovery passes isolated XPC integration;
an installed reboot test is pending. Automated XPC coverage also verifies
bounded reader recovery from startup resets and persistent failure.

0.8.4 partial pass on 2026-09-13: the installed driver reports version 0.8.4,
and read-only route verification passes, including the legacy output-scope
sample-rate query at 48000 Hz. The user confirmed Warcraft III starts without
the reported audio-device error. Game audio playback and broader compatibility
remain unverified.

Previous release status: **partial pass on 2026-09-12 for 0.8.3**. The user confirmed audible music
and two Disable/Enable cycles without errors. Live broker logs recorded three
successful authenticated grants; read-only driver checks passed. Remaining items
were unverified for that build, including a subsequent login. Record audible
playback on the candidate under test independently of the routing indicator.
This checklist guides intentional user testing; it does not authorize an agent
to install software, switch outputs, or generate test sounds without a request.

## Record before testing

- Date/tester:
- macOS version and Mac model:
- Physical device/model/connection:
- Normal output and system-sounds output before installation:
- Physical nominal sample rate (software routing requires 48 kHz):
- App/helper/driver versions (expected 0.9.1/build 23):
- DMG checksum/source (see [validation coverage](validation.md)):

Keep System Settings > Sound > Output available for recovery. Use ordinary
music at a comfortable physical-speaker level; no diagnostic tone is required.
If a microphone or recording permission prompt appears, decline, stop, and
record it. If audio disappears, select the real output manually before further
diagnosis. Do not uninstall while Sound Volume remains selected.

## First acceptance pass

- [ ] Install the matching DMG manually; record any Installer or Gatekeeper error.
- [ ] Reopen from Applications; the menu icon appears without a Dock window.
- [ ] First launch requests Start at Login and later changes to that setting persist.
- [ ] A fixed-volume output automatically selects Sound Volume after helper readiness.
- [ ] With no pending update or routing error, the dot is green when the helper
  confirms forwarding and gray on a native macOS route. Assess audible playback
  by listening. The dot can stay green while the display is muted.
- [ ] Existing music remains audible; starting a new playback app also works.
- [ ] No microphone/system-recording permission or unexpected privacy indicator.
- [ ] Control Center slider, Volume Up/Down keys, and native HUD behave correctly.
- [ ] 60% remains usable; compare several levels including near zero and 100%.
- [ ] Native mute silences actual output; unmute restores it without a stuck state.
- [ ] No duplicate/dry audio, feedback, obvious clipping, clicks, or excessive latency.
- [ ] Quit restores normal output and system-sounds output and stops the helper.
- [ ] Reopen and verify automatic volume control resumes.
- [ ] With Start at Login on, log out and back in and verify automatic routing.
- [ ] Verify **Check for Updates…** reports the current result. Turn off
  automatic checks, reopen the app, and confirm the preference persists and
  the manual check still works.

Record pass/fail and observations for each item. A failure blocks this first
acceptance gate even if unit tests passed.

## Reliability pass (only after the first pass)

- [ ] Switch between native and fixed-volume devices through the menu and
  System Settings. Verify direct routing on native devices and software
  volume on fixed-volume devices, with no routing prompts.
- [ ] Change output again while the helper is starting and verify the latest
  destination wins.
- [ ] Disconnect/reconnect the display; verify safe output and explicitly note
  whether macOS selected another physical output and forwarding followed it.
- [ ] Sleep/wake; separately test display sleep and computer sleep.
- [ ] Test helper/broker exit and restart under controlled conditions; verify
  the red routing-error status when a failure is reported and that both
  defaults return to usable physical outputs when available.
- [ ] Lock/unlock, logout/login, and real fast-user switching; verify revocation,
  no continued old-session audio access, and expected recovery behavior.
- [ ] Test Start at Login across reboot and verify that turning it off is respected.
- [ ] Test a fixed-volume output at an unsupported sample rate. Confirm the app
  reports the mismatch and leaves a usable physical route.
- [ ] With a known newer installer release or the automated test fixture,
  verify that an update appears in the menu and turns the dot yellow. With
  both an update and a routing error present, verify a red dot and both menu
  entries. After routing recovers, verify yellow returns.
- [ ] Run sustained playback; record duration, CPU/RAM, dropouts, latency, and drift.
- [ ] Update/uninstall through the complete DMG workflow; confirm broker cleanup
  and restoration. Use a controlled test when replacement/removal is intended.

## Public 1.0 release candidate

Run the checklist on the exact Developer ID-signed, notarized package planned
for release. Cover representative fixed-volume display or dock setups, a
native-volume output, and the oldest and newest macOS versions listed as
supported. Test a browser-downloaded clean install, an upgrade from the
published release, and an uninstall that restores both outputs. Allow about a
week of daily use after these checks pass. Treat unresolved app-caused audio
loss, routing failures, or installer failures as release blockers.

## Useful diagnostics and report

From the repository, `make audio-route-verify` reads driver properties only.
The commands `audio-route-exercise` and `audio-route-watch-temporary-default` do change
controls/routes and must be deliberately selected, not used as read-only probes.

For an error report include versions, target device, any Console errors, whether
the real output works directly, what was playing, when audio stopped, and which
restoration steps succeeded. Do not attach private audio recordings.

An optional diagnostic tone is described in the [user guide](user-guide.md).
Quit the menu app first; only one authenticated reader can connect. The helper
must match the installed signature policy. No tone is generated in normal use.

Record the final decision as PASS, FAIL, or NOT RUN and link a dated validation
record. The 0.9.1 package is ad-hoc signed and hardware acceptance
remains open.
