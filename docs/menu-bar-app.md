# Menu-bar app

- App: 0.8.8 (build 20), native arm64 development candidate
- Embedded helper: 0.8.8 (build 20)
- Driver: 0.8.8 (build 20)
- Small authenticated XPC broker, with no UI or audio processing
- Minimum macOS: 14.0

The app is a menu-bar-only `NSApplication`. It is installed in `/Applications`,
so closing it does not make it difficult to find: reopen it from Finder,
Spotlight, or Launchpad.

## Menu

The speaker icon stays constant. Its menu offers **Output Device**,
**Start at Login**, About, and Quit.

## Automatic routing

The app checks the physical destination for writable output volume controls
at launch and when the default output changes. A device with native volume
control uses the direct macOS route. For a confirmed fixed-volume device,
the app starts the helper while the physical route remains active. Once the
helper has mapped the ring and started physical output IO, the app selects
Sound Volume as the normal and system-sounds output. If the device capability
is unknown, the app waits for a usable output. Routing changes run in the
background, and failures are recorded in the system log.

On the first launch of this version, the app requests login registration
through macOS Service Management. Approval and later changes are managed
through **Start at Login** or System Settings.

## Recovery and Quit

Each startup attempt has a 25-second watchdog. Temporary startup failures and
unexpected signals after readiness restore the physical outputs and retry,
with delays of 1, 2, 4, 8, then at most 15 seconds. Authentication, busy-reader,
and format failures end that attempt. The app keeps monitoring for output
changes. Quit and output changes cancel pending retries.

Quit restores the default normal output and default system-sounds output
before stopping the helper. Each selector is changed only if it still points
at Sound Volume, preserving routes selected in System Settings. Writes are
read back and verified. Quit reports an error if restoration fails.

## Output selection

Automatic follows the current physical default. An explicit menu selection
stores the device UID and immediately applies the routing policy. An external
physical-output change supersedes an explicit selection and returns the app
to Automatic.

Duplicate notifications during startup leave the current attempt in place. A
different physical default replaces the pending attempt. Helper route-loss
messages and exits use the same output-change path.

## Privacy

The app and helper contain no microphone usage description and do not link
AVFoundation. The helper maps the output driver's ring read-only and creates
only a physical output IOProc. It does not create a virtual input callback,
ScreenCaptureKit stream, or Core Audio process tap.

The ring is anonymous and accessed through authenticated XPC with kernel-enforced
read-only capabilities. Broker and helper signatures are pinned, readers are
restricted to the active console user, and old mappings stop on revocation.
Installed hardware validation is still pending. See [Validation coverage](validation.md).
