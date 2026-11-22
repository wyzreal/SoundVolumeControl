# SoundVolumeControl user guide

Version 0.8.8 development candidate for Apple Silicon and macOS 14+.

Audio uses authenticated XPC and anonymous read-only memory. Installed playback
and hardware reliability still need [validation](validation.md).

Use the [manual acceptance checklist](manual-acceptance.md) to record results.

SoundVolumeControl gives the normal macOS volume keys and Control Center slider
software control over fixed-volume HDMI, DisplayPort, and USB-C display audio.
It stays in the menu bar and has no separate window or custom volume slider.

## Install from the DMG

1. If an older copy is running, use its **Quit SoundVolumeControl** command.
2. Open `SoundVolumeControl-0.8.8.dmg` from a trusted source.
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

SoundVolumeControl runs in the background whenever it is open. Devices
with native volume control stay on the direct macOS route. For fixed-volume
devices, the app automatically starts software volume control after the
helper is ready. Use the normal macOS volume keys, mute key, and Control
Center slider in both cases.

The speaker menu offers **Output Device**, **Start at Login**, About, and
Quit. **Automatic** follows the macOS output. Choose a specific device in
the menu to use it as the destination.

On the first launch of this version, the app asks macOS to start it at login.
You can change this from **Start at Login** or System Settings. **Quit**
restores the physical outputs and stops the helper. Reopen the app from
Applications, Spotlight, or Launchpad when needed.

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
performance still need testing. The app reevaluates the route on output changes.
Startup timeouts retry automatically. Other helper errors are recorded in the
system log.

## Troubleshooting

### There is no sound

1. Under **Output Device**, choose the HDMI, DisplayPort, or USB-C target.
2. Confirm the display or receiver uses the expected input and is unmuted.
3. If the problem persists, quit and reopen the app. Record the macOS version,
   output-device name, and any SoundVolumeControl errors from Console.

For a controlled development test, also report whether music remained audible,
whether the shared output callback advanced, and whether the explicit test tone
was audible. These distinguish app routing, driver capture, and physical output
failures.

### Buffer connection errors

Each buffer attempt waits up to 20 seconds. Cold boot can delay macOS service
launch and authentication beyond that deadline. Versions 0.8.7 and later
automatically start another attempt, with at most 15 seconds
between attempts. The physical output stays selected until the helper is ready.

- **Authentication rejected:** install all matching components from the same DMG.
- **Another audio helper is connected:** quit other running copies of the app.
- **Service disconnected:** quit and reopen the app. Report recurring errors.
- **Audio service still starting:** automatic retries are in progress. If it
  persists, report the macOS version, installed app version, and status detail.

### Quit does not restore sound

Open System Settings > Sound > Output and select a real device immediately.
Then reopen SoundVolumeControl so it can refresh its saved route. Do not uninstall the driver while Sound Volume is still selected.

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
