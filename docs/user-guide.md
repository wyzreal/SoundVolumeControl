# SoundVolumeControl user guide

Version 0.9.1 (build 23) for Apple Silicon and macOS 14+.

Audio uses authenticated XPC and anonymous read-only memory. Installed playback
and hardware reliability still need [validation](validation.md).

Use the [manual acceptance checklist](manual-acceptance.md) to record results.

SoundVolumeControl gives the normal macOS volume keys and Control Center slider
software control over fixed-volume HDMI, DisplayPort, and USB-C display audio.
It stays in the menu bar and has no separate window or custom volume slider.

## Install from the DMG

1. If an older copy is running, use its **Quit SoundVolumeControl** command.
2. Download `SoundVolumeControl-0.9.1.dmg` and `SHA256SUMS.txt`, then open the
   DMG. [0.9.1 GitHub release](https://github.com/wyzreal/SoundVolumeControl/releases/tag/v0.9.1)
3. Double-click **Install SoundVolumeControl.pkg**.
4. Follow Installer and enter an administrator password.
5. The installer adds `SoundVolumeControl.app` to `/Applications`, installs the
   matching Core Audio driver and small authenticated connection broker, briefly
   restarts Core Audio, and opens the app.

The DMG contains an ad-hoc-signed build. macOS may ask you to approve it in
Privacy & Security. Verify the download against `SHA256SUMS.txt` on the release
page before approving it. [Apple’s instructions for opening unnotarized software](https://support.apple.com/en-us/102445)

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

Choose a destination under **Output Device** in the speaker menu. The
app remembers choices made there and in macOS Sound settings.
When you reopen the app, it selects your last choice if connected. Otherwise
it tries your other remembered outputs, most recent first, then uses the
current macOS physical output.

Connecting or reconnecting a physical output switches audio to that device
automatically. Choose **Automatic** to follow the current macOS output again
until you connect another output or choose a device yourself.

The app requests **Start at Login** by default on first launch. macOS may
require approval. You can change the setting from the speaker menu or System
Settings. **Quit SoundVolumeControl** restores the physical outputs and stops
the helper. Reopen the app from Applications, Spotlight, or Launchpad when
needed.

### Status dot

| Dot | Meaning |
| --- | --- |
| Red | The app detected an audio routing error. |
| Yellow | A newer stable release with a compatible installer is available. |
| Green | The helper is actively routing through Sound Volume. |
| Gray | macOS controls the selected output directly. |
| Outlined gray | The app is preparing, retrying, or waiting for a compatible output. |

If an update and a routing error are present, the dot stays red and the menu
shows both. The dot turns yellow after routing recovers if the update is still
available. Green reports the software route. Confirm audible sound by playing
audio through the actual display or speakers.

## Volume behavior

Software volume for fixed-volume outputs uses a square-law amplitude curve:

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

1. Open the speaker menu and read the routing status. If it shows an error,
   note its details.
2. Under **Output Device**, confirm the intended destination.
3. If playback is silent while the menu says **Routing through Sound Volume**,
   check the display or receiver’s input, mute, volume, and cable connection.
4. If the problem persists, quit and reopen the app. Record the macOS version,
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

Choose **Start at Login — Approval Required** in the speaker menu to open
macOS Login Items settings. Approve SoundVolumeControl, then reopen its menu.

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

Choose **Check for Updates…** from the speaker menu to check now. **Check for
Updates Automatically** is on by default and checks quietly about once a day
while the app is running. Turning it off leaves manual checks available.

Choose **Update available** in the speaker menu, then **View Release** to open
its GitHub page. The menu remembers a confirmed update across launches and
failed checks. It clears the item when the installed version catches up or a
successful check finds no newer compatible release.

Download the installer DMG and quit the app before running the package. The
package updates the app, driver, broker, and signature policy together. It
asks for administrator approval and briefly restarts Core Audio.

To uninstall, open the DMG and double-click
**Uninstall SoundVolumeControl.command**. The uninstaller first uses the normal
Quit/restoration path, then requests administrator authorization, moves the app
and broker files to the Trash, unloads the broker, removes the driver, clears
legacy shared buffer names, and briefly restarts Core Audio. It refuses removal
while Sound Volume remains a default output.
