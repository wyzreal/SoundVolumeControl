<p align="center">
  <img src="app/Assets/AppIcon.png" width="144" alt="SoundVolumeControl icon">
</p>

# SoundVolumeControl — macOS volume control for external monitors

SoundVolumeControl is an extremely lightweight menu bar app for external audio
outputs whose volume macOS can’t adjust directly. It lets you use your Mac’s
volume keys, mute key, and Control Center with fixed-volume HDMI, DisplayPort,
and USB-C monitor speakers.

The app uses native macOS frameworks, and the v0.9.2 installer is a **2.1 MB download**.

[Download the latest macOS installer and SHA-256 checksum](https://github.com/wyzreal/SoundVolumeControl/releases/latest)

Requires **macOS 14 or later on Apple silicon**. The selected output must run
at **48 kHz stereo** for software volume control. Installed playback and hardware
validation are pending for 1.0. [Manual acceptance checklist](docs/manual-acceptance.md)

## Features

- Native macOS volume HUD and smooth volume changes.
- Automatic background routing, output selection, and configurable Start at Login.
- Menu-bar routing status and manual or automatic checks for stable GitHub releases.
- Startup readiness checks and physical output restoration before Quit.
- Output-only audio driver and authenticated, anonymous shared memory.
- No microphone or system-recording APIs.

## Install on macOS

Open the downloaded DMG and run **Install SoundVolumeControl.pkg**.
The installer requests administrator access, installs the matching app, driver,
broker, and signature policy, briefly restarts Core Audio, and opens the app.
The DMG contains ad-hoc-signed components. [Installation guide](docs/user-guide.md#install-from-the-dmg)

Choose **Quit SoundVolumeControl** to restore the physical outputs. To
uninstall, run **Uninstall SoundVolumeControl.command** from the DMG.

## How do I change HDMI volume on my Mac when the system slider is grayed out?

Choose your monitor under **Output Device** in the app’s speaker menu. When the
menu shows **Routing through Sound Volume**, use your keyboard volume keys or
the Control Center slider. The app adjusts the audio signal before it reaches
the monitor, so the monitor’s own volume setting stays the same. The same steps
apply to fixed-volume DisplayPort and USB-C outputs.

The green status dot shows that software routing is active. Play audio through
the monitor to confirm sound. Outputs that support native macOS volume control
use the direct audio route automatically.

## Build from source

Install Xcode Command Line Tools, then run from the repository root:

```sh
make check
make dmg
```

The build writes the matching installer to `dist/SoundVolumeControl-0.9.2.dmg`.

## How it works

```text
Applications → Sound Volume driver → anonymous audio ring
                                    ↓ read-only mapping
                              volume forwarder → physical output
```

The driver publishes the final Core Audio output mix. The forwarder applies a
square-law volume curve and a 5 ms smoothing ramp. A small broker authenticates
the Apple Core Audio host and the exact helper build, then passes a read-only
memory handle to the active console user's helper. The broker never maps PCM.

The virtual format is fixed at 48 kHz stereo, with no general sample-rate
conversion or amplification above unity. Device reconnect, sleep/wake, user
switching, native controls, and sustained playback remain manual acceptance gates.
Automated tests do not establish audible playback or an independent security audit.

## Contributing

The project uses C, Objective-C, system frameworks, and Make; no package manager
is required. Read the [developer guide](docs/development.md), run `make check`,
and include relevant verification with a pull request. For bug reports, include
the macOS/app versions, output device, exact error, and reproduction steps.

- [Architecture and trust boundaries](docs/architecture.md)
- [Menu-bar lifecycle](docs/menu-bar-app.md)
- [Validation coverage](docs/validation.md)
- [Manual acceptance checklist](docs/manual-acceptance.md)
- [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE). No eqMac source or binary code is copied.
