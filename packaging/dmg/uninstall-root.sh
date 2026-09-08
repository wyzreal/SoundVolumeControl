#!/bin/sh
set -eu

SYSTEM_APP="/Applications/SoundVolumeControl.app"
SYSTEM_DRIVER="/Library/Audio/Plug-Ins/HAL/SoundVolumeControl.driver"
SYSTEM_HELPER="$SYSTEM_APP/Contents/Helpers/SoundVolumeForwarder.app/Contents/MacOS/SoundVolumeForwarder"
BROKER="/Library/PrivilegedHelperTools/org.soundvolumecontrol.broker"
BROKER_PLIST="/Library/LaunchDaemons/org.soundvolumecontrol.broker.plist"
READER_POLICY="/Library/Application Support/SoundVolumeControl/reader.requirement"

if [ "$#" -ne 3 ] || [ "$(id -u)" -ne 0 ]; then
    echo "uninstall-root: invalid privileged invocation" >&2
    exit 64
fi

TRASH_TARGET=$1
OWNER_ID=$2
GROUP_ID=$3
case "$TRASH_TARGET" in
    /Users/*/.Trash/SoundVolumeControl-uninstall-*) ;;
    *)
        echo "uninstall-root: unsafe Trash target" >&2
        exit 64
        ;;
esac

/usr/bin/pkill -TERM -x SoundVolumeForwarder >/dev/null 2>&1 || true
if /bin/launchctl print system/org.soundvolumecontrol.broker >/dev/null 2>&1; then
    /bin/launchctl bootout system/org.soundvolumecontrol.broker
fi
if [ -x "$SYSTEM_HELPER" ]; then
    "$SYSTEM_HELPER" --remove-shared-audio >/dev/null 2>&1 || true
fi
if [ -e "$SYSTEM_APP" ]; then
    /bin/mkdir -p "$TRASH_TARGET"
    /bin/mv "$SYSTEM_APP" "$TRASH_TARGET/"
    /usr/sbin/chown -R "$OWNER_ID:$GROUP_ID" "$TRASH_TARGET"
fi
/bin/mkdir -p "$TRASH_TARGET/Broker"
for BROKER_FILE in "$BROKER" "$BROKER_PLIST" "$READER_POLICY"; do
    if [ -e "$BROKER_FILE" ]; then
        /bin/mv "$BROKER_FILE" "$TRASH_TARGET/Broker/"
    fi
done
/usr/sbin/chown -R "$OWNER_ID:$GROUP_ID" "$TRASH_TARGET"
if [ -e "$SYSTEM_DRIVER" ]; then
    /bin/rm -rf "$SYSTEM_DRIVER"
fi
/usr/bin/killall coreaudiod >/dev/null 2>&1 || true

exit 0
