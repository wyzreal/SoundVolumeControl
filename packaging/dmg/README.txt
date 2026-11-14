SoundVolumeControl 0.8.7 development candidate
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

0.8.7 fixes the recurring cold-boot error 60: macOS can finish launching and
authenticating the broker after the 20-second buffer deadline. The app now
retries temporary startup timeouts automatically with delays capped at 15
seconds, keeping the physical output active until ready. Disable and Quit
cancel retries. Authentication and competing-reader errors remain explicit.

The matching broker, driver, helper, and app must be installed together.

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

The driver also reconnects if the broker service is unavailable during boot.
Startup reader resets have their existing bounded retries (error 54).
Installed login recovery still needs manual verification.
