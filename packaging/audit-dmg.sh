#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then echo "usage: $0 DMG" >&2; exit 64; fi
IMAGE=$1
EXPECTED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Info.plist)
AUDIT_WORK=$(/usr/bin/mktemp -d /private/tmp/svc-dmg-audit.XXXXXX)
MOUNT="$AUDIT_WORK/mount"
MOUNTED=0
cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then /usr/bin/hdiutil detach "$MOUNT" >/dev/null || return; fi
    case "$AUDIT_WORK" in /private/tmp/svc-dmg-audit.*) /bin/rm -rf "$AUDIT_WORK" ;; esac
}
trap cleanup EXIT HUP INT TERM
/bin/mkdir "$MOUNT"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$IMAGE" >/dev/null
MOUNTED=1
/usr/sbin/pkgutil --expand-full "$MOUNT/Install SoundVolumeControl.pkg" "$AUDIT_WORK/expanded"
PAYLOAD="$AUDIT_WORK/expanded/Payload"
APP="$PAYLOAD/Applications/SoundVolumeControl.app"
HELPER="$APP/Contents/Helpers/SoundVolumeForwarder.app"
DRIVER="$PAYLOAD/Library/Audio/Plug-Ins/HAL/SoundVolumeControl.driver"
BROKER="$PAYLOAD/Library/PrivilegedHelperTools/org.soundvolumecontrol.broker"
POLICY="$PAYLOAD/Library/Application Support/SoundVolumeControl/reader.requirement"
for BUNDLE in "$APP" "$HELPER" "$DRIVER"; do
    /usr/bin/codesign --verify --strict "$BUNDLE"
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist")
    [ "$VERSION" = "$EXPECTED_VERSION" ]
    ! /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1
done
/usr/bin/codesign --verify --strict "$BROKER"
READER_REQUIREMENT=$(/bin/cat "$POLICY")
/usr/bin/codesign --verify --strict -R "=$READER_REQUIREMENT" "$HELPER"
for BUNDLE in "$HELPER" "$DRIVER"; do
    BROKER_REQUIREMENT=$(/usr/libexec/PlistBuddy -c 'Print :SVCBrokerRequirement' "$BUNDLE/Contents/Info.plist")
    /usr/bin/codesign --verify --strict -R "=$BROKER_REQUIREMENT" "$BROKER"
done
/usr/bin/cmp "$APP/Contents/Resources/AppIcon.icns" app/Assets/AppIcon.icns
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" = AppIcon ]
/usr/bin/cmp "$APP/Contents/MacOS/SoundVolumeControl" .build/SoundVolumeControl.app/Contents/MacOS/SoundVolumeControl
/usr/bin/cmp "$HELPER/Contents/MacOS/SoundVolumeForwarder" .build/SoundVolumeForwarder.app/Contents/MacOS/SoundVolumeForwarder
/usr/bin/cmp "$DRIVER/Contents/MacOS/SoundVolumeControl" .build/SoundVolumeControl.driver/Contents/MacOS/SoundVolumeControl
/usr/bin/cmp "$BROKER" .build/org.soundvolumecontrol.broker
/usr/bin/cmp "$POLICY" .build/reader.requirement
/usr/bin/cmp "$MOUNT/README.txt" packaging/dmg/README.txt
/usr/bin/cmp "$AUDIT_WORK/expanded/Scripts/audio-safety" .build/audio-route-verify
/usr/bin/cmp "$AUDIT_WORK/expanded/Scripts/preinstall" packaging/installer-scripts/preinstall
/usr/bin/cmp "$AUDIT_WORK/expanded/Scripts/postinstall" packaging/installer-scripts/postinstall
! /usr/bin/nm -u "$BROKER" "$DRIVER/Contents/MacOS/SoundVolumeControl" "$HELPER/Contents/MacOS/SoundVolumeForwarder" | /usr/bin/grep -E -q '_shm_open|_AudioHardwareCreateProcessTap|_AVCapture'
/usr/bin/plutil -lint "$PAYLOAD/Library/LaunchDaemons/org.soundvolumecontrol.broker.plist"
for SCRIPT in "$AUDIT_WORK/expanded/Scripts/preinstall" "$AUDIT_WORK/expanded/Scripts/postinstall" "$MOUNT/.support/uninstall-root.sh" "$MOUNT/Uninstall SoundVolumeControl.command"; do
    /bin/sh -n "$SCRIPT"
done
/usr/bin/lsbom "$AUDIT_WORK/expanded/Bom" | /usr/bin/grep -E 'PrivilegedHelperTools|LaunchDaemons|reader.requirement'
/usr/bin/shasum -a 256 "$IMAGE"
/usr/bin/stat -f '%z bytes' "$IMAGE"
echo "DMG audit: PASS (matching binaries, versions, signatures, broker/reader pins, scripts, no named audio IPC)"
