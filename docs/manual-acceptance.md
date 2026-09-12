# Manual acceptance — 0.8.3 candidate

Status: **partial pass on 2026-09-12 for 0.8.3**. The user confirmed audible music
and two Disable/Enable cycles without errors. Live broker logs recorded three
successful authenticated grants; read-only driver checks passed. Remaining items
are unverified, including a subsequent login. Do not infer a pass
from an automated test, an Enabled label, or earlier prototype observations.
This checklist guides intentional user testing; it does not authorize an agent
to install software, switch outputs, or generate test sounds without a request.

## Record before testing

- Date/tester:
- macOS version and Mac model:
- Physical device/model/connection:
- Normal output and system-sounds output before installation:
- Physical nominal sample rate (must match 48 kHz):
- App/helper/driver versions (expected 0.8.3/build 15):
- DMG checksum/source (see [validation coverage](validation.md)):

Keep System Settings > Sound > Output available for recovery. Use ordinary
music at a comfortable physical-speaker level; no diagnostic tone is required.
If a microphone or recording permission prompt appears, decline, stop, and
record it. If audio disappears, select the real output manually before further
diagnosis. Do not uninstall while Sound Volume remains selected.

## First acceptance pass

- [ ] Install the matching DMG manually; record any Installer or Gatekeeper error.
- [ ] Reopen from Applications; the menu icon appears without a Dock window.
- [ ] Start at Login is separately configurable; enabling it is optional.
- [ ] Enable completes, selects Sound Volume, and identifies the correct real output.
- [ ] Existing music remains audible; starting a new playback app also works.
- [ ] No microphone/system-recording permission or unexpected privacy indicator.
- [ ] Control Center slider, Volume Up/Down keys, and native HUD behave correctly.
- [ ] 60% remains usable; compare several levels including near zero and 100%.
- [ ] Native mute silences actual output; unmute restores it without a stuck state.
- [ ] No duplicate/dry audio, feedback, obvious clipping, clicks, or excessive latency.
- [ ] Disable restores normal output AND system-sounds output; music continues.
- [ ] Enable again, then Quit; both outputs are restored and the helper stops.
- [ ] Disable, Quit, then reopen; volume control enables automatically.
- [ ] With Start at Login on, log out and back in after disabling; volume control
  enables automatically once the helper is ready.

Record pass/fail and observations for each item. A failure blocks this first
acceptance gate even if the app shows Enabled or unit tests passed.

## Reliability pass (only after the first pass)

- [ ] Change physical output in the menu and externally in System Settings.
- [ ] Disconnect/reconnect the display; verify safe output and explicitly note
  whether re-enabling was required. Automatic re-enable is not guaranteed.
- [ ] Sleep/wake; separately test display sleep and computer sleep.
- [ ] Test helper/broker exit and restart under controlled conditions; verify
  restoration rather than leaving an inactive virtual default.
- [ ] Lock/unlock, logout/login, and real fast-user switching; verify revocation,
  no continued old-session audio access, and expected recovery behavior.
- [ ] Test Start at Login after explicit opt-in, and reopening after reboot.
- [ ] Test mismatched/unsupported sample rates: clear failure and safe output,
  not silent success. Do not assume the clock-drift correction resamples formats.
- [ ] Run sustained playback; record duration, CPU/RAM, dropouts, latency, and drift.
- [ ] Update/uninstall through the complete DMG workflow; confirm broker cleanup
  and restoration. Use a controlled test when replacement/removal is intended.

## Useful diagnostics and report

From the repository, `make audio-route-verify` reads driver properties only.
The commands `audio-route-exercise` and `audio-route-watch-temporary-default` do change
controls/routes and must be deliberately selected, not used as read-only probes.

For an error report include versions, target device, exact menu error, whether
the real output works directly, what was playing, when audio stopped, and which
restoration steps succeeded. Do not attach private audio recordings.

An optional diagnostic tone is described in the [user guide](user-guide.md).
Quit the menu app first; only one authenticated reader can connect. The helper
must match the installed signature policy. No tone is generated in normal use.

Final decision: PASS / FAIL / NOT RUN. Link results here or add a dated validation
record. Until then, this remains an ad-hoc-signed development candidate.
