#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
VERIFIER="$SCRIPT_DIR/.support/audio-route-verify"
ROOT_UNINSTALLER="$SCRIPT_DIR/.support/uninstall-root.sh"
SYSTEM_APP="/Applications/SoundVolumeControl.app"
APP_EXECUTABLE="$SYSTEM_APP/Contents/MacOS/SoundVolumeControl"
TRASH_TARGET="$HOME/.Trash/SoundVolumeControl-uninstall-$(date +%Y%m%d-%H%M%S)"
USER_ID=$(id -u)
GROUP_ID=$(id -g)

if /usr/bin/pgrep -x SoundVolumeControl >/dev/null 2>&1; then
    /usr/bin/osascript \
        -e 'tell application id "org.soundvolumecontrol.app" to quit' \
        >/dev/null 2>&1 || true
    ATTEMPT=0
    while /usr/bin/pgrep -x SoundVolumeControl >/dev/null 2>&1 \
        && [ "$ATTEMPT" -lt 100 ]; do
        /bin/sleep 0.1
        ATTEMPT=$((ATTEMPT + 1))
    done
    if /usr/bin/pgrep -x SoundVolumeControl >/dev/null 2>&1; then
        echo "Uninstall stopped: the app could not restore a real output." >&2
        echo "Select a real output in Sound settings, then try again." >&2
        exit 1
    fi
fi

if [ -x "$APP_EXECUTABLE" ]; then
    "$APP_EXECUTABLE" --unregister-login-item || true
fi
"$VERIFIER" --refuse-if-default
/usr/bin/sudo "$ROOT_UNINSTALLER" "$TRASH_TARGET" "$USER_ID" "$GROUP_ID"

echo "SoundVolumeControl was removed. The app is recoverable from $TRASH_TARGET"
echo "You can eject this disk image."
