CC := xcrun clang
CFLAGS := -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror -mmacosx-version-min=14.0
FORWARDER_CFLAGS := $(CFLAGS)
BUILD_DIR := .build
DRIVER_NAME := SoundVolumeControl
DRIVER_BUNDLE := $(BUILD_DIR)/$(DRIVER_NAME).driver
DRIVER_BINARY := $(DRIVER_BUNDLE)/Contents/MacOS/$(DRIVER_NAME)
DRIVER_PLIST := $(DRIVER_BUNDLE)/Contents/Info.plist
FORWARDER_APP := $(BUILD_DIR)/SoundVolumeForwarder.app
FORWARDER_BINARY := $(FORWARDER_APP)/Contents/MacOS/SoundVolumeForwarder
FORWARDER_PLIST := $(FORWARDER_APP)/Contents/Info.plist
MENU_APP := $(BUILD_DIR)/SoundVolumeControl.app
MENU_BINARY := $(MENU_APP)/Contents/MacOS/SoundVolumeControl
MENU_HELPER_APP := $(MENU_APP)/Contents/Helpers/SoundVolumeForwarder.app
MENU_HELPER := $(MENU_HELPER_APP)/Contents/MacOS/SoundVolumeForwarder
MENU_PLIST := $(MENU_APP)/Contents/Info.plist
MENU_ICON := $(MENU_APP)/Contents/Resources/AppIcon.icns
PROBE := $(BUILD_DIR)/audio-device-probe
ROUTE_VERIFY := $(BUILD_DIR)/audio-route-verify
CONTRACT_TEST := $(BUILD_DIR)/driver-contract-tests
PROCESSOR_TEST := $(BUILD_DIR)/audio-processor-tests
SHARED_READER_TEST := $(BUILD_DIR)/shared-audio-reader-tests
VOLUME_CURVE_TEST := $(BUILD_DIR)/volume-curve-tests
IPC_TEST := $(BUILD_DIR)/audio-ipc-tests
APP_TEST := $(BUILD_DIR)/app-lifecycle-tests
TRANSPORT := tests/legacy/SharedAudioTransport.c
SECURE_MEMORY := common/SecureAudioMemory.c
SECURE_WRITER := common/SecureAudioWriter.c
SECURE_READER := common/SecureAudioReader.c
BROKER := $(BUILD_DIR)/org.soundvolumecontrol.broker
POLICY_TOOL := $(BUILD_DIR)/signing-policy
READER_POLICY := $(BUILD_DIR)/reader.requirement
SECURE_MEMORY_TEST := $(BUILD_DIR)/secure-memory-tests
SECURE_BROKER_TEST := $(BUILD_DIR)/secure-broker-test
SECURE_WRITER_TEST := $(BUILD_DIR)/secure-writer-test
SECURE_READER_TEST := $(BUILD_DIR)/secure-reader-test
SECURE_RUNNER := $(BUILD_DIR)/secure-ipc-tests
APP_VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Info.plist)
DIST_DIR := dist
DMG := $(DIST_DIR)/SoundVolumeControl-$(APP_VERSION).dmg
PACKAGE_FILES := packaging/build-dmg.sh packaging/components.plist \
    broker/org.soundvolumecontrol.broker.plist \
	packaging/installer-scripts/preinstall packaging/installer-scripts/postinstall \
	packaging/dmg/README.txt \
	packaging/dmg/Uninstall\ SoundVolumeControl.command \
	packaging/dmg/uninstall-root.sh

.PHONY: all driver forwarder menu-app dmg forwarder-run probe probe-run audio-route-verify audio-route-exercise audio-route-watch audio-route-watch-temporary-default driver-test processor-test shared-reader-test volume-curve-test privacy-audit check clean

all: driver forwarder menu-app $(READER_POLICY) probe $(ROUTE_VERIFY) driver-test processor-test shared-reader-test volume-curve-test app-test

$(BROKER): broker/main.c common/SecureAudio.h common/SharedAudio.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -fblocks -Icommon $< -framework CoreFoundation -framework SystemConfiguration -o $@
	/usr/bin/codesign --force --options runtime --sign - "$@"

$(POLICY_TOOL): tools/signing-policy.c
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $< -framework Security -framework CoreFoundation -o $@

$(READER_POLICY): $(FORWARDER_APP) $(POLICY_TOOL)
	$(POLICY_TOOL) $(FORWARDER_BINARY) $@ policy

$(SECURE_MEMORY_TEST): tests/secure-memory-tests.c $(SECURE_MEMORY) common/SecureAudio.h common/SharedAudio.h
	$(CC) $(CFLAGS) -Icommon $< $(SECURE_MEMORY) -framework CoreFoundation -o $@

$(SECURE_BROKER_TEST): broker/main.c common/SecureAudio.h common/SharedAudio.h
	$(CC) $(CFLAGS) -fblocks -DSVC_BROKER_TESTING -Icommon $< -framework CoreFoundation -framework SystemConfiguration -o $@
	/usr/bin/codesign --force --options runtime --sign - "$@"

$(SECURE_WRITER_TEST): tests/secure-writer-test.c driver/SoundVolumeControl.c $(SECURE_MEMORY) $(SECURE_WRITER) common/SecureAudio.h common/SharedAudio.h
	$(CC) $(CFLAGS) -fblocks -DSVC_SECURE_IPC_TESTING -Icommon -Idriver $< driver/SoundVolumeControl.c $(SECURE_MEMORY) $(SECURE_WRITER) -framework CoreAudio -framework CoreFoundation -o $@
	/usr/bin/codesign --force --options runtime --sign - "$@"

$(SECURE_READER_TEST): tests/secure-reader-test.c $(SECURE_MEMORY) $(SECURE_READER) forwarder/SharedAudioReader.c common/SecureAudio.h common/SharedAudio.h
	$(CC) $(CFLAGS) -fblocks -Icommon -Iforwarder $< $(SECURE_MEMORY) $(SECURE_READER) forwarder/SharedAudioReader.c -framework CoreFoundation -o $@
	/usr/bin/codesign --force --options runtime --sign - "$@"

$(SECURE_RUNNER): tests/secure-ipc-tests.m $(SECURE_MEMORY) $(SECURE_READER) common/SecureAudio.h
	$(CC) $(CFLAGS) -fobjc-arc -fblocks -Icommon $< $(SECURE_MEMORY) $(SECURE_READER) -framework Foundation -framework Security -o $@
	/usr/bin/codesign --force --options runtime --sign - "$@"

.PHONY: secure-test
secure-test: $(SECURE_MEMORY_TEST) $(SECURE_BROKER_TEST) $(SECURE_WRITER_TEST) $(SECURE_READER_TEST) $(SECURE_RUNNER) $(POLICY_TOOL)
	$(SECURE_MEMORY_TEST)
	$(SECURE_RUNNER)

driver: $(DRIVER_BUNDLE)

$(DRIVER_BUNDLE): $(DRIVER_BINARY) $(DRIVER_PLIST)
	/usr/bin/codesign --force --sign - "$@"
	touch "$@"

$(DRIVER_BINARY): driver/SoundVolumeControl.c driver/SoundVolumeControlIDs.h common/SharedAudio.h common/SecureAudio.h $(SECURE_MEMORY) $(SECURE_WRITER) common/VolumeCurve.h
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fblocks -fvisibility=hidden -Icommon -bundle driver/SoundVolumeControl.c $(SECURE_MEMORY) $(SECURE_WRITER) \
		-framework CoreAudio -framework CoreFoundation -o $@

$(DRIVER_PLIST): driver/Info.plist $(BROKER) $(POLICY_TOOL)
	mkdir -p $(dir $@)
	cp $< $@
	$(POLICY_TOOL) $(BROKER) $@ plist

forwarder: $(FORWARDER_APP)

$(FORWARDER_APP): $(FORWARDER_BINARY) $(FORWARDER_PLIST)
	/usr/bin/codesign --force --options runtime --sign - "$@"
	touch "$@"

$(FORWARDER_BINARY): forwarder/main.m forwarder/AudioProcessor.c forwarder/AudioProcessor.h forwarder/SharedAudioReader.c forwarder/SharedAudioReader.h driver/SoundVolumeControlIDs.h common/SharedAudio.h common/SecureAudio.h $(SECURE_MEMORY) $(SECURE_READER) common/VolumeCurve.h
	mkdir -p $(dir $@)
	$(CC) $(FORWARDER_CFLAGS) -fblocks -fobjc-arc -Icommon -Idriver -Iforwarder \
		forwarder/main.m forwarder/AudioProcessor.c forwarder/SharedAudioReader.c $(SECURE_MEMORY) $(SECURE_READER) \
		-framework CoreAudio -framework CoreFoundation \
		-framework Foundation -o $@

$(FORWARDER_PLIST): forwarder/Info.plist $(BROKER) $(POLICY_TOOL)
	mkdir -p $(dir $@)
	cp $< $@
	$(POLICY_TOOL) $(BROKER) $@ plist

menu-app: $(MENU_APP)

$(MENU_APP): $(MENU_BINARY) $(MENU_HELPER_APP) $(MENU_PLIST) $(MENU_ICON)
	/usr/bin/codesign --force --sign - "$@"
	touch "$@"

$(MENU_BINARY): app/main.m driver/SoundVolumeControlIDs.h
	mkdir -p $(dir $@)
	$(CC) $(FORWARDER_CFLAGS) -fobjc-arc -fblocks -Idriver app/main.m \
		-framework AppKit -framework CoreAudio -framework Foundation \
		-framework ServiceManagement -o $@

$(MENU_HELPER_APP): $(FORWARDER_BINARY) $(FORWARDER_PLIST) | $(FORWARDER_APP)
	mkdir -p $(dir $@)
	/usr/bin/ditto $(FORWARDER_APP) $@
	touch "$@"

$(MENU_PLIST): app/Info.plist
	mkdir -p $(dir $@)
	cp $< $@

$(MENU_ICON): app/Assets/AppIcon.icns
	mkdir -p $(dir $@)
	cp $< $@

forwarder-run: $(FORWARDER_APP)
	$(FORWARDER_BINARY) --diagnose --always-active

probe: $(PROBE)

$(PROBE): tools/audio-device-probe.c
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $< -framework CoreAudio -framework CoreFoundation -o $@

probe-run: $(PROBE)
	$(PROBE)

$(ROUTE_VERIFY): tools/audio-route-verify.c driver/SoundVolumeControlIDs.h common/VolumeCurve.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -Icommon -Idriver $< -framework CoreAudio -framework CoreFoundation -o $@

audio-route-verify: $(ROUTE_VERIFY)
	$(ROUTE_VERIFY)

audio-route-exercise: $(ROUTE_VERIFY)
	$(ROUTE_VERIFY) --exercise-controls

audio-route-watch: $(ROUTE_VERIFY)
	$(ROUTE_VERIFY) --watch-native

audio-route-watch-temporary-default: $(ROUTE_VERIFY)
	$(ROUTE_VERIFY) --watch-native-temporary-default

$(CONTRACT_TEST): tests/driver-contract-tests.c driver/SoundVolumeControl.c driver/SoundVolumeControlIDs.h common/SharedAudio.h common/VolumeCurve.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -DSVC_TESTING -Icommon -Idriver tests/driver-contract-tests.c driver/SoundVolumeControl.c \
		-framework CoreAudio -framework CoreFoundation -o $@

driver-test: $(CONTRACT_TEST)
	$(CONTRACT_TEST)

$(PROCESSOR_TEST): tests/audio-processor-tests.c forwarder/AudioProcessor.c forwarder/AudioProcessor.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -Iforwarder tests/audio-processor-tests.c forwarder/AudioProcessor.c -o $@

processor-test: $(PROCESSOR_TEST)
	$(PROCESSOR_TEST)

$(SHARED_READER_TEST): tests/shared-audio-reader-tests.c forwarder/SharedAudioReader.c forwarder/SharedAudioReader.h common/SharedAudio.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -Icommon -Iforwarder tests/shared-audio-reader-tests.c \
		forwarder/SharedAudioReader.c -o $@

shared-reader-test: $(SHARED_READER_TEST)
	$(SHARED_READER_TEST)

$(VOLUME_CURVE_TEST): tests/volume-curve-tests.c common/VolumeCurve.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -Icommon $< -framework CoreAudio -o $@

volume-curve-test: $(VOLUME_CURVE_TEST)
	$(VOLUME_CURVE_TEST)

privacy-audit: $(DRIVER_BUNDLE) $(FORWARDER_APP) $(MENU_APP)
	! /usr/bin/otool -L $(FORWARDER_BINARY) | /usr/bin/grep -q AVFoundation
	! /usr/bin/strings $(FORWARDER_BINARY) $(MENU_BINARY) | /usr/bin/grep -E -q 'AVCaptureDevice|ScreenCaptureKit|AudioHardwareCreateProcessTap'
	! /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' $(FORWARDER_PLIST) >/dev/null 2>&1
	! /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' $(MENU_PLIST) >/dev/null 2>&1
	! /usr/bin/nm -u $(DRIVER_BINARY) $(FORWARDER_BINARY) $(BROKER) | /usr/bin/grep -E -q '_shm_open|_AudioHardwareCreateProcessTap|_AVCapture'
	! /usr/bin/strings $(BROKER) | /usr/bin/grep -q test-revoke

.PHONY: ipc-test app-test
$(APP_TEST): tests/app-lifecycle-tests.m app/main.m driver/SoundVolumeControlIDs.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(FORWARDER_CFLAGS) -fobjc-arc -fblocks -Idriver $< \
		-framework AppKit -framework CoreAudio -framework Foundation \
		-framework ServiceManagement -o $@

app-test: $(APP_TEST)
	$(APP_TEST)

$(IPC_TEST): tests/legacy/audio-ipc-tests.c driver/SoundVolumeControl.c driver/SoundVolumeControlIDs.h $(TRANSPORT) common/SharedAudio.h tests/legacy/SharedAudioTransport.h common/VolumeCurve.h forwarder/SharedAudioReader.c forwarder/SharedAudioReader.h forwarder/AudioProcessor.c forwarder/AudioProcessor.h
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -DSVC_IPC_TESTING -Itests/legacy -Icommon -Idriver -Iforwarder \
		tests/legacy/audio-ipc-tests.c driver/SoundVolumeControl.c $(TRANSPORT) \
		forwarder/SharedAudioReader.c forwarder/AudioProcessor.c \
		-framework CoreAudio -framework CoreFoundation -o $@

ipc-test: $(IPC_TEST)
	$(IPC_TEST)

check: all privacy-audit ipc-test secure-test
	/usr/bin/plutil -lint $(DRIVER_PLIST)
	/usr/bin/plutil -lint $(FORWARDER_PLIST)
	/usr/bin/plutil -lint $(MENU_PLIST)
	/usr/bin/plutil -lint broker/org.soundvolumecontrol.broker.plist
	/usr/bin/codesign --verify --strict --verbose=2 $(BROKER)
	/usr/bin/codesign --verify --strict --verbose=2 $(DRIVER_BUNDLE)
	/usr/bin/codesign --verify --strict --verbose=2 $(FORWARDER_APP)
	/usr/bin/codesign --verify --strict --verbose=2 $(MENU_APP)
	/usr/bin/file $(DRIVER_BINARY)
	/usr/bin/file $(FORWARDER_BINARY)
	/usr/bin/file $(MENU_BINARY)

dmg: $(DMG)

$(DMG): check $(PACKAGE_FILES) LICENSE
	packaging/build-dmg.sh $(MENU_APP) $(DRIVER_BUNDLE) $(ROUTE_VERIFY) \
		LICENSE $(APP_VERSION) "$@" $(BROKER) $(READER_POLICY)

clean:
	rm -rf $(BUILD_DIR)
