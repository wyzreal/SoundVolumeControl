SoundVolumeControl 0.8.2 development candidate
============================================

INSTALL MANUALLY

1. Quit an older SoundVolumeControl through its normal menu.
2. Open “Install SoundVolumeControl.pkg” and follow Installer prompts.
3. The installer adds the app to Applications, the output-only driver, and a
   small authenticated connection broker. Core Audio briefly restarts.
4. The app opens enabled and selects Sound Volume only after output is ready.
5. Use its menu for Enable/Disable, Output Device, Start at Login, About, Quit.
   Use normal macOS volume controls; there is no extra slider.

Reopen the app from Applications or Spotlight when closed.

WHAT CHANGED

0.8.1 fixes error 60 caused by the broker rejecting Apple’s separate Core Audio
driver helper. The exact helper identity is now allowed with Apple-signature
verification still required. Install the complete matching package.

The old globally readable audio buffer is replaced by anonymous memory and
authenticated XPC. The broker checks the Apple Core Audio host, exact helper
build, and active console user. Clients check the broker too. The kernel
enforces read-only access; reconnects get fresh buffers and old mappings stop.

The broker does not process or record audio and adds no UI. No microphone,
ScreenCaptureKit, or process-tap API is used. Decline and report any privacy
prompt rather than granting permission as a workaround.

INSTALLED FILES

- /Applications/SoundVolumeControl.app (with embedded forwarder)
- /Library/Audio/Plug-Ins/HAL/SoundVolumeControl.driver
- /Library/PrivilegedHelperTools/org.soundvolumecontrol.broker
- /Library/LaunchDaemons/org.soundvolumecontrol.broker.plist
- /Library/Application Support/SoundVolumeControl/reader.requirement

Update all components through the matching installer. Do not replace or
re-sign the helper independently: the broker rejects mismatched builds.

UNINSTALL

Open “Uninstall SoundVolumeControl.command”. It restores a real output and
refuses removal if Sound Volume remains selected. After administrator approval,
it unloads the broker, moves the app and broker files to Trash, removes the
driver, and briefly restarts Core Audio. The driver can be reinstalled from the DMG.

DEVELOPMENT STATUS

Tests passed for separate-process driver audio, authentication, wrong-identity
rejection, read-only memory, reconnect rotation, and session revocation.
Installed HAL sandbox behavior and audible music remain unverified for this
candidate. First test playback, native controls, 60%, mute, Disable, and Quit.
If sound is absent, select your real output in System Settings > Sound > Output
and report the app error plus macOS and output-device details.

This local build is ad-hoc signed, not Developer ID signed or notarized.
macOS may require Control-click > Open or Privacy & Security approval.
Install only from a trusted source. No independent security audit is claimed.
