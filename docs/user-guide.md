# SoundVolumeControl user guide

Version 0.8.3 development candidate for Apple Silicon and macOS 14+.

Audio uses authenticated XPC and anonymous read-only memory. Installed playback
and hardware reliability still need [validation](validation.md).

Use the [manual acceptance checklist](manual-acceptance.md) to record results.

SoundVolumeControl gives the normal macOS volume keys and Control Center slider
software control over fixed-volume HDMI, DisplayPort, and USB-C display audio.
It stays in the menu bar and has no separate window or custom volume slider.

## Install from the DMG

1. If an older copy is running, use its **Quit SoundVolumeControl** command.
2. Open `SoundVolumeControl-0.8.3.dmg` from a trusted source.
3. Double-click **Install SoundVolumeControl.pkg**.
4. Follow Installer and enter an administrator password.
5. The installer adds `SoundVolumeControl.app` to `/Applications`, installs the
   matching Core Audio driver and small authenticated connection broker, briefly
   restarts Core Audio, and opens the app.

The development DMG is ad-hoc signed rather than notarized. If macOS blocks it,
Control-click the item and choose Open, or approve it in Privacy & Security.
Install only a DMG built from this source or received through a trusted channel.

The intended output-only path uses neither microphone nor system-recording APIs.
If macOS asks for either permission during validation, decline, quit, and report
the installed versions. Absence of those prompts still needs hardware validation;
it does not establish that the IPC buffer is private.

## Normal use

The app enables volume control on every launch, including Start at Login.
A speaker icon in the menu bar shows its
state:

- **Enabled — device name**: routing and helper readiness were acknowledged;
  this status alone does not prove that non-silent music reaches the speakers.
- **Disabled**: macOS is using a normal physical output.
- **Enabling…**: the helper is starting.
- **Error — detail**: enabling failed and the app attempted to restore a real
  output.

The menu contains:

- **Enable** or **Disable** — one action whose name reflects what it will do.
- **Output Device** — Automatic is recommended; select a device only when the
  automatic choice is wrong.
- **Start at Login** — uses macOS Service Management.
- **About SoundVolumeControl**.
- **Quit SoundVolumeControl**.

Use the standard volume keys, keyboard mute key, or Control Center while the
menu says Enabled. The app does not provide another slider.

## Enable, Disable, and Quit

Enable remembers the current real output, starts the lightweight helper, and
waits for physical-output readiness, then makes Sound Volume the normal and
system-sounds output. A failed startup times out after 25 seconds.

Disable applies to the current session and restores the remembered real outputs
before stopping the helper. Reopening the app enables volume control again. Quit
uses the same restoration path. If restoration cannot be verified, the app
shows an error instead of silently leaving the Mac routed to an inactive virtual
device. An unexpected helper exit also triggers restoration.

If the app has been closed, reopen it from `/Applications`, Spotlight, or
Launchpad.

## Volume behavior

The volume control uses a square-law amplitude curve:

| macOS volume | Approximate amplitude | Approximate level |
| ---: | ---: | ---: |
| 100% | 100% | 0 dB |
| 60% | 36% | -8.9 dB |
| 50% | 25% | -12.0 dB |
| 10% | 1% | -40 dB |
| 0% | 0% | silence |

This avoids the earlier overly steep decibel mapping. At 60% the app should not
mathematically reduce the signal to silence, but perceived loudness also depends
on the source and physical speaker settings. Changes use a 5 ms smoothing ramp.

### Current compatibility limits

The virtual stream is 48 kHz stereo. The physical device must report the same
positive nominal rate; otherwise startup reports a sample-rate mismatch and
does not enable the route. Small clock-drift correction is not general sample-rate
conversion. Device reconnect, sleep/wake, real user switching, and long-run
performance still need testing. After failure the app may disable forwarding;
automatic re-enable is not guaranteed.

## Troubleshooting

### Enabled but there is no sound

1. Open the menu and confirm it says **Enabled — expected device**.
2. Under **Output Device**, choose the actual HDMI/display/USB-C target rather
   than Automatic.
3. Choose Disable, then Enable.
4. Confirm the physical display or receiver is not muted and uses the expected
   input.
5. If the problem persists, Quit so the physical output is restored and record
   the macOS version, output-device name, and whether the menu showed an error.

For a controlled development test, also report whether music remained audible,
whether the shared output callback advanced, and whether the explicit test tone
was audible. These distinguish app routing, driver capture, and physical output
failures.

### Buffer connection errors

Version 0.8.3 replaces a one-way request that could hide rejected signatures as
error 60 with an authenticated reply. Cold buffer setup can take up to 20 seconds.
The app keeps the physical output selected until the helper reports readiness.

- **Authentication rejected:** install all matching components from the same DMG.
- **Another audio helper is connected:** quit other running copies of the app.
- **Service disconnected:** try Enable again; if it repeats, report the error.
- **No buffer within 20 seconds:** the service or driver did not complete setup;
  report the macOS version and installed app version.

### Quit does not restore sound

Open System Settings > Sound > Output and select a real device immediately.
Then reopen SoundVolumeControl and use Disable once so it can refresh its saved
route. Do not uninstall the driver while Sound Volume is still selected.

### macOS asks for microphone access

Current source exposes no virtual input and explicitly disables physical input
streams before starting its output IOProc. Decline the prompt and quit; record the app and driver versions rather
than granting permission as a workaround.

### Start at Login needs approval

Open System Settings > General > Login Items and approve SoundVolumeControl,
then reopen its menu.

## Diagnostic tone

Developers can run a one-second 440 Hz signal through the exact driver and
physical-output route after installing the matching build:

Quit the menu app first: only one authenticated reader may connect. Use the
exact helper build matching the installed signature policy. This command is
audible and optional, not part of routine installation or documentation checks.

```sh
.build/SoundVolumeControl.app/Contents/Helpers/SoundVolumeForwarder.app/Contents/MacOS/SoundVolumeForwarder \
  --diagnose --always-active --test-tone --run-seconds 3
```

Normal app operation never generates a tone.

## Update and uninstall

Use Quit before installing an update. Install the app, driver, broker, and policy from the same
DMG; mixed versions are deliberately rejected by signature checks.

To uninstall, open the DMG and double-click
**Uninstall SoundVolumeControl.command**. The uninstaller first uses the normal
Quit/restoration path, then requests administrator authorization, moves the app
and broker files to the Trash, unloads the broker, removes the driver, clears
legacy shared buffer names, and briefly restarts Core Audio. It refuses removal
while Sound Volume remains a default output.
