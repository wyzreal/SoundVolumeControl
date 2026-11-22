# Menu-bar app

- App: 0.9.0 (build 22), native arm64
- Embedded helper: 0.9.0 (build 22)
- Driver: 0.9.0 (build 22)
- Small authenticated XPC broker, with no UI or audio processing
- Minimum macOS: 14.0

The app is a menu-bar-only `NSApplication`. It is installed in `/Applications`,
so closing it does not make it difficult to find: reopen it from Finder,
Spotlight, or Launchpad.

## Menu

The first menu line shows the current routing status, including the output name
or error detail when available. The dot beside the speaker follows this priority
from highest to lowest.

1. **Red** for an audio routing error the app detected.
2. **Yellow** for a confirmed newer stable release with a compatible installer.
3. **Green** when the helper is actively routing through Sound Volume or **gray**
   when macOS controls the output directly. An outlined gray dot indicates
   startup, retry, or a wait for a compatible output.

Green reports the software routing state. Verify audible sound at the display
or speakers. Display input, mute, and cable faults can leave the dot green.

When a routing error and an update are present, the menu shows both. The dot
turns yellow once routing recovers if the update is still available. The menu
also offers **Output Device**, **Start at Login**, About, and Quit.

## Update checks

**Check for Updates…** checks for a newer published stable GitHub release with
a compatible installer DMG and reports the result. **Check for Updates
Automatically** is on by default and remembers your preference. The app checks
on launch when a check is due, then about once a day while it runs. Background
checks stay quiet and retry later if they fail. You can check manually with
automatic checks turned off.

An available update stays in the menu across launches and failed checks. The
item clears when the installed version catches up or a successful check
confirms there is no newer compatible release. Choose the available update
to view the release details and open the official release page. Install the
matching package manually when you are ready for a brief Core Audio restart.

## Automatic routing

The app checks the physical destination for writable output volume controls
at launch and when the default output changes. A device with native volume
control uses the direct macOS route. For a confirmed fixed-volume device,
the app starts the helper while the physical route remains active. Once the
helper has mapped the ring and started physical output IO, the app selects
Sound Volume as the normal and system-sounds output. If the device capability
is unknown, the app waits for a usable output. Routing changes run in the
background, and failures are recorded in the system log.

The app requests **Start at Login** by default on first launch through macOS
Service Management. Approval and later changes are managed through **Start at
Login** or System Settings.

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
