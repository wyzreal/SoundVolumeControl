#!/bin/sh
set -eu

if [ "$#" -ne 8 ]; then
    echo "usage: $0 APP DRIVER VERIFIER LICENSE VERSION OUTPUT_DMG BROKER READER_POLICY" >&2
    exit 64
fi

SOURCE_APP=$1
SOURCE_DRIVER=$2
SOURCE_VERIFIER=$3
SOURCE_LICENSE=$4
PACKAGE_VERSION=$5
OUTPUT_DMG=$6
SOURCE_BROKER=$7
SOURCE_READER_POLICY=$8
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
/bin/mkdir -p "$(dirname "$OUTPUT_DMG")"
OUTPUT_PARENT=$(cd "$(dirname "$OUTPUT_DMG")" && pwd -P)
OUTPUT_DMG="$OUTPUT_PARENT/$(basename "$OUTPUT_DMG")"
PACKAGE_WORK=$(/usr/bin/mktemp -d /private/tmp/soundvolume-dmg.XXXXXX)

cleanup() {
    case "$PACKAGE_WORK" in
        /private/tmp/soundvolume-dmg.*)
            /bin/rm -rf "$PACKAGE_WORK"
            ;;
    esac
}
trap cleanup EXIT HUP INT TERM

PAYLOAD_ROOT="$PACKAGE_WORK/payload"
PACKAGE_SCRIPTS="$PACKAGE_WORK/installer-scripts"
DMG_ROOT="$PACKAGE_WORK/dmg"
COMPONENT_PACKAGE="$DMG_ROOT/Install SoundVolumeControl.pkg"

/bin/mkdir -p "$PAYLOAD_ROOT/Applications"
/bin/mkdir -p "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL"
/bin/mkdir -p "$PAYLOAD_ROOT/Library/PrivilegedHelperTools"
/bin/mkdir -p "$PAYLOAD_ROOT/Library/LaunchDaemons"
/bin/mkdir -p "$PAYLOAD_ROOT/Library/Application Support/SoundVolumeControl"
/bin/mkdir -p "$PACKAGE_SCRIPTS"
/bin/mkdir -p "$DMG_ROOT/.support"

/usr/bin/ditto --norsrc "$SOURCE_APP" \
    "$PAYLOAD_ROOT/Applications/SoundVolumeControl.app"
/usr/bin/ditto --norsrc "$SOURCE_DRIVER" \
    "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/SoundVolumeControl.driver"
/bin/cp -X "$SOURCE_BROKER" "$PAYLOAD_ROOT/Library/PrivilegedHelperTools/org.soundvolumecontrol.broker"
/bin/cp -X "$SOURCE_READER_POLICY" "$PAYLOAD_ROOT/Library/Application Support/SoundVolumeControl/reader.requirement"
/bin/cp -X "$SCRIPT_DIR/../broker/org.soundvolumecontrol.broker.plist" "$PAYLOAD_ROOT/Library/LaunchDaemons/"
/bin/chmod 755 "$PAYLOAD_ROOT/Library/PrivilegedHelperTools/org.soundvolumecontrol.broker"
/bin/chmod 644 "$PAYLOAD_ROOT/Library/LaunchDaemons/org.soundvolumecontrol.broker.plist" \
    "$PAYLOAD_ROOT/Library/Application Support/SoundVolumeControl/reader.requirement"
/usr/bin/ditto --norsrc "$SCRIPT_DIR/installer-scripts" "$PACKAGE_SCRIPTS"
/bin/cp -X "$SOURCE_VERIFIER" "$PACKAGE_SCRIPTS/audio-safety"
/bin/chmod 755 "$PACKAGE_SCRIPTS/audio-safety"
/bin/chmod 755 "$PACKAGE_SCRIPTS/preinstall" "$PACKAGE_SCRIPTS/postinstall"
/usr/bin/codesign --verify --strict \
    "$PAYLOAD_ROOT/Applications/SoundVolumeControl.app"
/usr/bin/codesign --verify --strict \
    "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/SoundVolumeControl.driver"
/usr/bin/codesign --verify --strict "$PAYLOAD_ROOT/Library/PrivilegedHelperTools/org.soundvolumecontrol.broker"
READER_REQUIREMENT=$(/bin/cat "$SOURCE_READER_POLICY")
/usr/bin/codesign --verify --strict -R "=$READER_REQUIREMENT" \
    "$PAYLOAD_ROOT/Applications/SoundVolumeControl.app/Contents/Helpers/SoundVolumeForwarder.app"
# Remove transferable xattrs after verification and ask pkgbuild not to copy
# them. macOS may immediately restore protected local provenance metadata;
# expanded packages can show that metadata as AppleDouble records, which
# Installer restores as xattrs rather than visible files.
/usr/bin/xattr -cr "$PAYLOAD_ROOT"

COPYFILE_DISABLE=1 /usr/bin/pkgbuild \
    --root "$PAYLOAD_ROOT" \
    --component-plist "$SCRIPT_DIR/components.plist" \
    --scripts "$PACKAGE_SCRIPTS" \
    --identifier org.soundvolumecontrol.install \
    --version "$PACKAGE_VERSION" \
    --install-location / \
    --ownership recommended \
    --min-os-version 14.0 \
    "$COMPONENT_PACKAGE"

/bin/cp -X "$SCRIPT_DIR/dmg/README.txt" "$DMG_ROOT/README.txt"
/bin/cp -X "$SOURCE_LICENSE" "$DMG_ROOT/LICENSE.txt"
/bin/cp -X "$SCRIPT_DIR/dmg/Uninstall SoundVolumeControl.command" \
    "$DMG_ROOT/Uninstall SoundVolumeControl.command"
/bin/cp -X "$SCRIPT_DIR/dmg/uninstall-root.sh" \
    "$DMG_ROOT/.support/uninstall-root.sh"
/bin/cp -X "$SOURCE_VERIFIER" "$DMG_ROOT/.support/audio-route-verify"
/bin/chmod 755 "$DMG_ROOT/Uninstall SoundVolumeControl.command"
/bin/chmod 755 "$DMG_ROOT/.support/uninstall-root.sh"
/bin/chmod 755 "$DMG_ROOT/.support/audio-route-verify"
/usr/bin/xattr -cr "$DMG_ROOT"

/bin/rm -f "$OUTPUT_DMG"
/usr/bin/hdiutil create \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname "SoundVolumeControl $PACKAGE_VERSION" \
    -srcfolder "$DMG_ROOT" \
    "$OUTPUT_DMG"
/usr/bin/hdiutil verify "$OUTPUT_DMG"

echo "Created $OUTPUT_DMG"
