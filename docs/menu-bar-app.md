# Menu-bar app

- App: 0.8.3 (build 15), native arm64 development candidate
- Embedded helper: 0.8.3 (build 15)
- Driver: 0.8.3 (build 15)
- Small authenticated XPC broker, with no UI or audio processing
- Minimum macOS: 14.0

The app is a menu-bar-only `NSApplication`. It is installed in `/Applications`,
so closing it does not make it difficult to find: reopen it from Finder,
Spotlight, or Launchpad.

## Menu

The menu is intentionally small:

- a non-clickable current status;
- one dynamic **Enable** or **Disable** command;
- **Output Device** with Automatic and explicit physical choices;
- **Start at Login**;
- About;
- Quit.

There is no “Use volume now” command, duplicate enabled state, custom volume
slider, EQ control, recorder, permission screen, or advanced audio panel.

## Default behavior

`forwardingEnabled` is reset to true on every launch, including Start at Login.
The app starts its embedded helper and selects Sound Volume after readiness.
Users can choose Disable for the current session; a previous disable or helper
failure does not prevent the next launch from enabling volume control.
Start at Login is separately controlled by
`SMAppService.mainAppService`.

## Enable sequence

1. Resolve Sound Volume by UID.
2. Capture the current real normal and system-output UIDs.
3. Resolve the selected or automatic physical destination.
4. Launch the nested helper with that optional destination UID.
5. Wait for the helper to map the ring and start physical output-only IO.
6. After its ready acknowledgement, select Sound Volume as normal and system
   output; show **Enabled — physical device** after the active acknowledgement.

Startup times out after 25 seconds. Changing physical output first restores
the real defaults, then restarts the helper through the same readiness sequence.

If any step fails, stop the helper, restore the saved real outputs, persist the
disabled state, and show a concise error.

## Disable and Quit

Both paths restore the default normal output and default system output before
stopping the helper. Each selector is changed only if it still points at Sound
Volume, preserving a route the user changed in System Settings. Writes are read
back and verified. Normal Quit is refused if a real output cannot be restored.

An unexpected helper exit uses the same restoration code, clears the enabled
preference, and shows an error state. Termination requested by Disable or Quit
is distinguished from an unexpected exit by launch generation and task state.

## Output selection

Automatic chooses the current real default when possible, then the saved helper
destination, then the best available non-virtual output. HDMI/DisplayPort and
USB/Thunderbolt are preferred over built-in, Bluetooth, and AirPlay. Explicit
selection stores only the device UID and restarts the helper when enabled.

## Privacy

The app and helper contain no microphone usage description and do not link
AVFoundation. The helper maps the output driver's ring read-only and creates
only a physical output IOProc. It does not create a virtual input callback,
ScreenCaptureKit stream, or Core Audio process tap.

The ring is anonymous and accessed through authenticated XPC with kernel-enforced
read-only capabilities. Broker and helper signatures are pinned, readers are
restricted to the active console user, and old mappings stop on revocation.
Installed hardware validation is still pending. See [Validation coverage](validation.md).
