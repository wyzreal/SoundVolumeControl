#import <AppKit/AppKit.h>
#import <CoreAudio/AudioHardware.h>
#import <ServiceManagement/ServiceManagement.h>

#include "SoundVolumeControlIDs.h"
#include "../common/StartupTiming.h"

#include <stdbool.h>
#include <sysexits.h>
#include <os/log.h>

typedef NS_ENUM(NSInteger, SVCAppState) {
    SVCAppStateNativeVolume,
    SVCAppStateNoEligibleOutput,
    SVCAppStateStarting,
    SVCAppStateForwarding,
    SVCAppStateError,
};

typedef NS_ENUM(NSInteger, SVCVolumeSupport) {
    SVCVolumeSupportUnknown,
    SVCVolumeSupportFixed,
    SVCVolumeSupportNative,
};

static AudioObjectPropertyAddress SVCAddress(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope
) {
    return (AudioObjectPropertyAddress) {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
}

static BOOL SVCReadUInt32(AudioObjectID objectID,
                          AudioObjectPropertyAddress address,
                          UInt32 *value) {
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(objectID, &address, 0, NULL,
                                      &size, value) == noErr;
}

static NSString *SVCCopyString(AudioObjectID objectID,
                               AudioObjectPropertyAddress address) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(objectID, &address, 0, NULL,
                                   &size, &value) != noErr || value == NULL) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static NSInteger SVCOutputChannelCount(AudioDeviceID device);

static AudioDeviceID SVCDeviceForUID(NSString *uid) {
    if (uid.length == 0) {
        return kAudioObjectUnknown;
    }
    CFStringRef uidRef = (__bridge CFStringRef)uid;
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = SVCAddress(
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal
    );
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                   sizeof(uidRef), &uidRef,
                                   &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static AudioDeviceID SVCDefaultDevice(
    AudioObjectPropertySelector selector
) {
    AudioDeviceID device = kAudioObjectUnknown;
    (void)SVCReadUInt32(kAudioObjectSystemObject,
                        SVCAddress(selector, kAudioObjectPropertyScopeGlobal),
                        &device);
    return device;
}

static BOOL SVCIsPhysicalOutput(AudioDeviceID device) {
    if (device == kAudioObjectUnknown || SVCOutputChannelCount(device) <= 0) {
        return NO;
    }
    UInt32 transport = kAudioDeviceTransportTypeUnknown;
    return SVCReadUInt32(device,
                         SVCAddress(kAudioDevicePropertyTransportType,
                                    kAudioObjectPropertyScopeGlobal),
                         &transport)
        && transport != kAudioDeviceTransportTypeVirtual
        && transport != kAudioDeviceTransportTypeAggregate;
}

static BOOL SVCSetDefaultDevice(AudioObjectPropertySelector selector,
                                AudioDeviceID device) {
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = SVCAddress(
        selector, kAudioObjectPropertyScopeGlobal
    );
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &address,
                                      0, NULL, size, &device) == noErr;
}

static NSInteger SVCOutputChannelCount(AudioDeviceID device) {
    AudioObjectPropertyAddress address = SVCAddress(
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeOutput
    );
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr
        || size < sizeof(AudioBufferList)) {
        return 0;
    }
    AudioBufferList *list = malloc(size);
    if (list == NULL) {
        return 0;
    }
    if (AudioObjectGetPropertyData(device, &address, 0, NULL,
                                   &size, list) != noErr) {
        free(list);
        return 0;
    }
    NSInteger channels = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        channels += list->mBuffers[index].mNumberChannels;
    }
    free(list);
    return channels;
}

static SVCVolumeSupport SVCVolumeSupportAtElement(
    AudioDeviceID device, AudioObjectPropertyElement element
) {
    const AudioObjectPropertySelector selectors[] = {
        kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyVolumeDecibels,
    };
    SVCVolumeSupport support = SVCVolumeSupportFixed;
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); ++i) {
        AudioObjectPropertyAddress address = {
            selectors[i], kAudioObjectPropertyScopeOutput, element,
        };
        if (!AudioObjectHasProperty(device, &address)) continue;
        Boolean writable = false;
        if (AudioObjectIsPropertySettable(device, &address, &writable) != noErr) {
            support = SVCVolumeSupportUnknown;
        } else if (writable) {
            return SVCVolumeSupportNative;
        }
    }
    return support;
}

static SVCVolumeSupport SVCOutputVolumeSupport(AudioDeviceID device) {
    if (!SVCIsPhysicalOutput(device)) return SVCVolumeSupportUnknown;
    SVCVolumeSupport main = SVCVolumeSupportAtElement(
        device, kAudioObjectPropertyElementMain
    );
    if (main == SVCVolumeSupportNative) return main;

    NSInteger channels = SVCOutputChannelCount(device);
    if (channels <= 0) return SVCVolumeSupportUnknown;
    UInt32 stereo[2];
    UInt32 size = sizeof(stereo);
    AudioObjectPropertyAddress address = SVCAddress(
        kAudioDevicePropertyPreferredChannelsForStereo,
        kAudioObjectPropertyScopeOutput
    );
    BOOL hasStereoPair = channels >= 2
        && AudioObjectGetPropertyData(device, &address, 0, NULL, &size, stereo) == noErr
        && size == sizeof(stereo) && stereo[0] > 0 && stereo[1] > 0
        && stereo[0] <= channels && stereo[1] <= channels && stereo[0] != stereo[1];

    // A main control or controls for both sides of stereo can cover playback.
    // With no preferred pair, require volume controls for the whole output.
    SVCVolumeSupport channelSupport = SVCVolumeSupportNative;
    for (NSInteger i = 0; i < (hasStereoPair ? 2 : channels); ++i) {
        UInt32 element = hasStereoPair ? stereo[i] : (UInt32)(i + 1);
        SVCVolumeSupport support = SVCVolumeSupportAtElement(device, element);
        if (support == SVCVolumeSupportFixed) {
            channelSupport = support;
            break;
        }
        if (support == SVCVolumeSupportUnknown) channelSupport = support;
    }
    if (channelSupport == SVCVolumeSupportNative) return channelSupport;
    UInt32 alive = 0;
    if (main == SVCVolumeSupportUnknown || channelSupport == SVCVolumeSupportUnknown
        || !SVCReadUInt32(device,
            SVCAddress(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            &alive) || !alive) {
        return SVCVolumeSupportUnknown;
    }
    return SVCVolumeSupportFixed;
}

static NSArray<NSDictionary<NSString *, id> *> *SVCPhysicalOutputs(void) {
    AudioObjectPropertyAddress address = SVCAddress(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal
    );
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address,
                                       0, NULL, &size) != noErr || size == 0) {
        return @[];
    }
    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) {
        return @[];
    }
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                   0, NULL, &size, devices) != noErr) {
        free(devices);
        return @[];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *outputs =
        [NSMutableArray array];
    NSUInteger count = size / sizeof(AudioDeviceID);
    for (NSUInteger index = 0; index < count; ++index) {
        AudioDeviceID device = devices[index];
        if (SVCOutputChannelCount(device) <= 0) {
            continue;
        }
        UInt32 transport = kAudioDeviceTransportTypeUnknown;
        if (!SVCReadUInt32(device,
                           SVCAddress(kAudioDevicePropertyTransportType,
                                      kAudioObjectPropertyScopeGlobal),
                           &transport)
            || transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate) {
            continue;
        }
        NSString *uid = SVCCopyString(
            device,
            SVCAddress(kAudioDevicePropertyDeviceUID,
                       kAudioObjectPropertyScopeGlobal)
        );
        NSString *name = SVCCopyString(
            device,
            SVCAddress(kAudioObjectPropertyName,
                       kAudioObjectPropertyScopeGlobal)
        );
        if (uid.length == 0 || name.length == 0) {
            continue;
        }
        [outputs addObject:@{
            @"uid": uid,
            @"name": name,
            @"device": @(device),
        }];
    }
    free(devices);
    [outputs sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                       NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
    return outputs;
}

@interface SVCAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSMenuItem *statusMenuItem;
@property(nonatomic, strong) NSMenuItem *loginMenuItem;
@property(nonatomic, strong) NSMenuItem *outputMenuItem;
@property(nonatomic, strong) NSTask *forwarderTask;
@property(nonatomic, strong) NSTask *stoppingForwarderTask;
@property(nonatomic, strong) NSPipe *forwarderPipe;
@property(nonatomic, strong) NSMutableData *lineBuffer;
@property(nonatomic, copy) NSString *physicalOutputUID;
@property(nonatomic, copy) NSString *errorDetail;
@property(nonatomic, copy) NSString *lastPhysicalDefaultUID;
@property(nonatomic, copy) NSString *lastPhysicalSystemUID;
@property(nonatomic, copy) NSString *startingPhysicalDefaultUID;
@property(nonatomic) SVCAppState appState;
@property(nonatomic) BOOL quitting;
@property(nonatomic) BOOL defaultOutputListenerInstalled;
@property(nonatomic) BOOL defaultSystemListenerInstalled;
@property(nonatomic) NSUInteger launchGeneration;
@property(nonatomic) NSUInteger startupRetryDelay;
@property(nonatomic) BOOL startupRetryPending;
@property(nonatomic) BOOL forwarderReady;
- (void)capturePhysicalDefaults;
- (NSString *)currentPhysicalDefaultUID;
- (BOOL)soundVolumeIsDefaultOutput;
- (SVCVolumeSupport)volumeSupportForOutputUID:(NSString *)uid;
- (BOOL)selectDirectOutputWithUID:(NSString *)uid detail:(NSString **)outDetail;
- (BOOL)prepareOutputForForwarding:(NSString **)outUID detail:(NSString **)outDetail;
- (void)defaultDevicesDidChange;
- (BOOL)launchForwarder;
- (BOOL)selectSoundVolumeWithDetail:(NSString **)outDetail;
- (void)scheduleAfterSeconds:(NSTimeInterval)seconds action:(dispatch_block_t)action;
- (void)forwarderDidTerminateWithStatus:(int)status
                               reason:(NSTaskTerminationReason)reason
                           generation:(NSUInteger)generation;
- (void)forwarderStartupTimedOutForGeneration:(NSUInteger)generation;
@end

static OSStatus SVCDefaultDeviceChanged(
    AudioObjectID objectID,
    UInt32 numberAddresses,
    const AudioObjectPropertyAddress addresses[],
    void *clientData
) {
    (void)objectID;
    (void)numberAddresses;
    (void)addresses;
    SVCAppDelegate *delegate = (__bridge SVCAppDelegate *)clientData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate defaultDevicesDidChange];
    });
    return noErr;
}

@implementation SVCAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"physicalDeviceUID": @"",
        @"lastPhysicalDefaultUID": @"",
        @"lastPhysicalSystemUID": @"",
    }];
    self.lastPhysicalDefaultUID = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"lastPhysicalDefaultUID"];
    self.lastPhysicalSystemUID = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"lastPhysicalSystemUID"];
    [self installDefaultDeviceListeners];
    [self capturePhysicalDefaults];

    self.lineBuffer = [NSMutableData data];
    self.appState = SVCAppStateStarting;
    self.statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.autosaveName = @"org.soundvolumecontrol.status-item";
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"speaker.wave.2"
                             accessibilityDescription:@"SoundVolumeControl"];
    icon.template = YES;
    self.statusItem.button.image = icon;
    self.statusItem.button.imagePosition = NSImageLeft;
    self.menu = [[NSMenu alloc] initWithTitle:@"SoundVolumeControl"];
    self.menu.delegate = self;
    self.statusItem.menu = self.menu;
    [self buildMenu];
    [self registerDefaultLoginItem];
    [self updateLoginMenu];
    if (![self launchForwarder]) {
        os_log_error(OS_LOG_DEFAULT, "SoundVolumeControl: audio startup failed: %{public}@",
                     self.errorDetail);
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:
    (NSApplication *)sender {
    (void)sender;
    NSString *detail = nil;
    if (![self restorePhysicalDefaults:&detail]) {
        [self showErrorWithTitle:@"Sound output was not restored"
                         detail:detail];
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    (void)[self restorePhysicalDefaults:NULL];
    self.quitting = YES;
    [self removeDefaultDeviceListeners];
    [self stopForwarder];
}

- (void)installDefaultDeviceListeners {
    AudioObjectPropertyAddress output = SVCAddress(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal
    );
    AudioObjectPropertyAddress system = SVCAddress(
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal
    );
    if (AudioObjectAddPropertyListener(kAudioObjectSystemObject, &output,
                                       SVCDefaultDeviceChanged,
                                       (__bridge void *)self) == noErr) {
        self.defaultOutputListenerInstalled = YES;
    }
    if (AudioObjectAddPropertyListener(kAudioObjectSystemObject, &system,
                                       SVCDefaultDeviceChanged,
                                       (__bridge void *)self) == noErr) {
        self.defaultSystemListenerInstalled = YES;
    }
}

- (void)removeDefaultDeviceListeners {
    AudioObjectPropertyAddress output = SVCAddress(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal
    );
    AudioObjectPropertyAddress system = SVCAddress(
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal
    );
    if (self.defaultOutputListenerInstalled) {
        (void)AudioObjectRemovePropertyListener(
            kAudioObjectSystemObject, &output,
            SVCDefaultDeviceChanged, (__bridge void *)self
        );
        self.defaultOutputListenerInstalled = NO;
    }
    if (self.defaultSystemListenerInstalled) {
        (void)AudioObjectRemovePropertyListener(
            kAudioObjectSystemObject, &system,
            SVCDefaultDeviceChanged, (__bridge void *)self
        );
        self.defaultSystemListenerInstalled = NO;
    }
}

- (NSString *)currentPhysicalDefaultUID {
    AudioDeviceID output = SVCDefaultDevice(
        kAudioHardwarePropertyDefaultOutputDevice
    );
    if (!SVCIsPhysicalOutput(output)) return nil;
    return SVCCopyString(
        output,
        SVCAddress(kAudioDevicePropertyDeviceUID,
                   kAudioObjectPropertyScopeGlobal)
    );
}

- (BOOL)soundVolumeIsDefaultOutput {
    AudioDeviceID device = SVCDeviceForUID(@SVC_DEVICE_UID);
    return device != kAudioObjectUnknown && device == SVCDefaultDevice(
        kAudioHardwarePropertyDefaultOutputDevice
    );
}

- (SVCVolumeSupport)volumeSupportForOutputUID:(NSString *)uid {
    return SVCOutputVolumeSupport(SVCDeviceForUID(uid));
}

- (BOOL)selectDirectOutputWithUID:(NSString *)uid detail:(NSString **)outDetail {
    AudioObjectPropertySelector selector = kAudioHardwarePropertyDefaultOutputDevice;
    AudioDeviceID device = SVCDeviceForUID(uid);
    if (SVCIsPhysicalOutput(device)
        && (SVCDefaultDevice(selector) == device
            || (SVCSetDefaultDevice(selector, device) && SVCDefaultDevice(selector) == device))) {
        return YES;
    }
    if (outDetail != NULL) *outDetail = @"macOS could not select the requested output.";
    return NO;
}

- (BOOL)prepareOutputForForwarding:(NSString **)outUID detail:(NSString **)outDetail {
    NSString *selectedUID = [self selectedPhysicalUID];
    NSString *defaultUID = [self currentPhysicalDefaultUID];
    NSString *uid = selectedUID.length > 0 ? selectedUID : defaultUID;
    SVCVolumeSupport support = [self volumeSupportForOutputUID:uid];
    self.startingPhysicalDefaultUID = defaultUID;
    if (support == SVCVolumeSupportFixed) {
        *outUID = uid;
        return YES;
    }

    if (support == SVCVolumeSupportNative && selectedUID.length > 0
        && ![selectedUID isEqualToString:defaultUID]) {
        if (![self selectDirectOutputWithUID:selectedUID detail:outDetail]) return NO;
        self.startingPhysicalDefaultUID = selectedUID;
    }
    *outUID = nil;
    self.physicalOutputUID = nil;
    self.errorDetail = nil;
    self.appState = support == SVCVolumeSupportNative
        ? SVCAppStateNativeVolume : SVCAppStateNoEligibleOutput;
    return YES;
}

- (void)capturePhysicalDefaults {
    NSString *uid = [self currentPhysicalDefaultUID];
    if (uid.length > 0) {
        self.lastPhysicalDefaultUID = uid;
        [[NSUserDefaults standardUserDefaults]
            setObject:uid forKey:@"lastPhysicalDefaultUID"];
    }

    AudioDeviceID system = SVCDefaultDevice(
        kAudioHardwarePropertyDefaultSystemOutputDevice
    );
    if (SVCIsPhysicalOutput(system)) {
        NSString *uid = SVCCopyString(
            system,
            SVCAddress(kAudioDevicePropertyDeviceUID,
                       kAudioObjectPropertyScopeGlobal)
        );
        if (uid.length > 0) {
            self.lastPhysicalSystemUID = uid;
            [[NSUserDefaults standardUserDefaults]
                setObject:uid forKey:@"lastPhysicalSystemUID"];
        }
    }
}

- (void)defaultDevicesDidChange {
    [self capturePhysicalDefaults];
    if (self.quitting) {
        return;
    }
    NSString *uid = [self currentPhysicalDefaultUID];
    if (uid.length == 0 && [self soundVolumeIsDefaultOutput]) {
        // Automatic routing can run without a helper. Restore a real
        // output if Sound Volume was selected while the app was waiting.
        if (self.appState == SVCAppStateNativeVolume
            || self.appState == SVCAppStateNoEligibleOutput) {
            [self restartForwarderForDefaultChange:NO];
        }
        return;
    }
    // Our own route changes generate notifications as well. Ignore duplicates
    // while the physical output is still selected.
    if (!self.forwarderReady
        && (uid == self.startingPhysicalDefaultUID
            || [uid isEqualToString:self.startingPhysicalDefaultUID])) {
        if (self.appState == SVCAppStateNoEligibleOutput && uid.length > 0) {
            [self restartForwarder:nil];
        }
        return;
    }
    // A choice in macOS Sound settings supersedes any previous explicit
    // destination. Automatic follows the newly selected physical default.
    [[NSUserDefaults standardUserDefaults] setObject:@""
                                              forKey:@"physicalDeviceUID"];
    self.physicalOutputUID = nil;
    [self restartForwarderForDefaultChange:YES];
}

- (NSString *)savedForwarderPhysicalUID {
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR("physicalDeviceUID"), CFSTR("org.soundvolumecontrol.forwarder")
    );
    if (value == NULL) {
        return @"";
    }
    NSString *uid = @"";
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        uid = [(__bridge NSString *)value copy];
    }
    CFRelease(value);
    return uid;
}

- (NSString *)firstUsableUIDFromCandidates:(NSArray<NSString *> *)candidates {
    for (NSString *uid in candidates) {
        if (uid.length > 0 && SVCIsPhysicalOutput(SVCDeviceForUID(uid))) {
            return uid;
        }
    }
    NSArray<NSDictionary<NSString *, id> *> *outputs = SVCPhysicalOutputs();
    return outputs.count == 0 ? @"" : outputs[0][@"uid"];
}

- (BOOL)restorePhysicalDefaults:(NSString **)outDetail {
    AudioDeviceID virtualDevice = SVCDeviceForUID(@SVC_DEVICE_UID);
    if (virtualDevice == kAudioObjectUnknown) {
        return YES;
    }

    NSString *selectedUID = [self selectedPhysicalUID];
    NSString *savedUID = [self savedForwarderPhysicalUID];
    NSString *runtimeUID = self.physicalOutputUID == nil
        ? @"" : self.physicalOutputUID;
    NSString *lastOutputUID = self.lastPhysicalDefaultUID == nil
        ? @"" : self.lastPhysicalDefaultUID;
    NSString *lastSystemUID = self.lastPhysicalSystemUID == nil
        ? @"" : self.lastPhysicalSystemUID;
    NSString *outputUID = [self firstUsableUIDFromCandidates:@[
        selectedUID,
        runtimeUID,
        lastOutputUID,
        savedUID,
    ]];
    NSString *systemUID = [self firstUsableUIDFromCandidates:@[
        lastSystemUID,
        outputUID,
    ]];

    AudioDeviceID currentOutput = SVCDefaultDevice(
        kAudioHardwarePropertyDefaultOutputDevice
    );
    if (currentOutput == virtualDevice) {
        AudioDeviceID target = SVCDeviceForUID(outputUID);
        if (!SVCIsPhysicalOutput(target)
            || !SVCSetDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice,
                                    target)) {
            if (outDetail != NULL) {
                *outDetail = @"No usable physical output could be restored as the default output.";
            }
            return NO;
        }
    }

    AudioDeviceID currentSystem = SVCDefaultDevice(
        kAudioHardwarePropertyDefaultSystemOutputDevice
    );
    if (currentSystem == virtualDevice) {
        AudioDeviceID target = SVCDeviceForUID(systemUID);
        if (!SVCIsPhysicalOutput(target)
            || !SVCSetDefaultDevice(
                kAudioHardwarePropertyDefaultSystemOutputDevice, target
            )) {
            if (outDetail != NULL) {
                *outDetail = @"The default output was restored, but the system-sounds output was not.";
            }
            return NO;
        }
    }
    return YES;
}

- (NSString *)selectedPhysicalUID {
    NSString *uid = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"physicalDeviceUID"];
    return uid == nil ? @"" : uid;
}

- (void)buildMenu {
    [self.menu removeAllItems];

    self.statusMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"" action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [self.menu addItem:self.statusMenuItem];
    [self.menu addItem:[NSMenuItem separatorItem]];
    [self updateRoutingStatus];

    self.outputMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Output Device" action:nil keyEquivalent:@""];
    [self.menu addItem:self.outputMenuItem];

    self.loginMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Start at Login"
               action:@selector(toggleStartAtLogin:)
        keyEquivalent:@""];
    self.loginMenuItem.target = self;
    [self.menu addItem:self.loginMenuItem];

    [self.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *about = [[NSMenuItem alloc]
        initWithTitle:@"About SoundVolumeControl"
               action:@selector(showAbout:)
        keyEquivalent:@""];
    about.target = self;
    [self.menu addItem:about];

    [self.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit SoundVolumeControl"
               action:@selector(quit:)
        keyEquivalent:@"q"];
    quit.target = self;
    [self.menu addItem:quit];
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self updateRoutingStatus];
    [self rebuildPhysicalOutputMenu];
    [self updateLoginMenu];
}

- (void)setAppState:(SVCAppState)appState {
    _appState = appState;
    [self updateRoutingStatus];
}

- (void)updateRoutingStatus {
    if (self.statusMenuItem == nil) return;

    NSColor *color = NSColor.systemGrayColor;
    NSString *dot = @"●";
    NSString *status = nil;
    NSString *outputUID = nil;
    switch (self.appState) {
        case SVCAppStateNativeVolume:
            status = @"Using macOS volume control";
            outputUID = [self currentPhysicalDefaultUID];
            break;
        case SVCAppStateForwarding:
            color = NSColor.systemGreenColor;
            status = @"Routing through Sound Volume";
            outputUID = self.physicalOutputUID;
            break;
        case SVCAppStateError:
            color = NSColor.systemRedColor;
            status = self.errorDetail.length > 0
                ? [NSString stringWithFormat:@"Error — %@", self.errorDetail]
                : @"Audio routing error";
            break;
        case SVCAppStateStarting:
            dot = @"○";
            status = self.startupRetryPending
                ? @"Retrying audio helper"
                : @"Preparing Sound Volume";
            break;
        case SVCAppStateNoEligibleOutput:
            dot = @"○";
            status = @"Waiting for a compatible output";
            break;
    }

    if (outputUID.length > 0) {
        NSString *name = SVCCopyString(SVCDeviceForUID(outputUID),
            SVCAddress(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal));
        if (name.length > 0) {
            status = [NSString stringWithFormat:@"%@ — %@", status, name];
        }
    }
    self.statusMenuItem.title = status;
    NSStatusBarButton *button = self.statusItem.button;
    button.attributedTitle = [[NSAttributedString alloc] initWithString:dot attributes:@{
        NSForegroundColorAttributeName: color,
        NSFontAttributeName: [NSFont systemFontOfSize:10],
    }];
    button.toolTip = status;
    [button setAccessibilityLabel:[NSString stringWithFormat:@"SoundVolumeControl, %@", status]];
}

- (void)rebuildPhysicalOutputMenu {
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Output Device"];
    NSString *selectedUID = [self selectedPhysicalUID];

    NSMenuItem *automatic = [[NSMenuItem alloc]
        initWithTitle:@"Automatic"
               action:@selector(selectPhysicalOutput:)
        keyEquivalent:@""];
    automatic.target = self;
    automatic.representedObject = @"";
    automatic.state = selectedUID.length == 0
        ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:automatic];

    NSArray<NSDictionary<NSString *, id> *> *outputs = SVCPhysicalOutputs();
    if (outputs.count > 0) {
        [submenu addItem:[NSMenuItem separatorItem]];
    }
    for (NSDictionary<NSString *, id> *output in outputs) {
        NSString *uid = output[@"uid"];
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:output[@"name"]
                   action:@selector(selectPhysicalOutput:)
            keyEquivalent:@""];
        item.target = self;
        item.representedObject = uid;
        item.state = [uid isEqualToString:selectedUID]
            ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }
    self.outputMenuItem.submenu = submenu;
}

- (void)updateLoginMenu {
    SMAppServiceStatus loginStatus = SMAppService.mainAppService.status;
    if (loginStatus == SMAppServiceStatusEnabled) {
        self.loginMenuItem.state = NSControlStateValueOn;
        self.loginMenuItem.title = @"Start at Login";
    } else if (loginStatus == SMAppServiceStatusRequiresApproval) {
        self.loginMenuItem.state = NSControlStateValueMixed;
        self.loginMenuItem.title = @"Start at Login — Approval Required";
    } else {
        self.loginMenuItem.state = NSControlStateValueOff;
        self.loginMenuItem.title = @"Start at Login";
    }
}

- (BOOL)launchForwarder {
    if (self.forwarderTask.running) {
        return YES;
    }
    if (self.quitting) {
        return NO;
    }
    NSString *restorationDetail = nil;
    if (![self restorePhysicalDefaults:&restorationDetail]) {
        self.errorDetail = restorationDetail.length > 0
            ? restorationDetail : @"The physical output could not be restored.";
        self.appState = SVCAppStateError;
        return NO;
    }
    NSString *physicalUID = nil;
    if (![self prepareOutputForForwarding:&physicalUID detail:&restorationDetail]) {
        self.errorDetail = restorationDetail;
        self.appState = SVCAppStateError;
        return NO;
    }
    if (physicalUID == nil) return YES;
    // A watchdog or an output change may have stopped a helper that
    // is still unwinding a system call. Preserve it across cancelled retries.
    if (self.stoppingForwarderTask.running) {
        self.appState = SVCAppStateStarting;
        [self launchAfterDelay:1 waitingForTask:self.stoppingForwarderTask
                   generation:self.launchGeneration];
        return YES;
    }
    self.stoppingForwarderTask = nil;
    NSURL *helperURL = [[NSBundle mainBundle].bundleURL
        URLByAppendingPathComponent:
            @"Contents/Helpers/SoundVolumeForwarder.app/Contents/MacOS/"
             "SoundVolumeForwarder"];
    if (![[NSFileManager defaultManager]
            isExecutableFileAtPath:helperURL.path]) {
        self.errorDetail = @"bundled helper is missing";
        self.appState = SVCAppStateError;
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = helperURL;
    task.arguments = @[@"--physical-uid", physicalUID];
    self.physicalOutputUID = physicalUID;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    self.forwarderTask = task;
    self.forwarderPipe = pipe;
    [self.lineBuffer setLength:0];
    self.errorDetail = nil;
    self.startupRetryPending = NO;
    self.forwarderReady = NO;
    self.appState = SVCAppStateStarting;

    NSUInteger generation = ++self.launchGeneration;
    __weak SVCAppDelegate *weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) {
            handle.readabilityHandler = nil;
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            SVCAppDelegate *strongSelf = weakSelf;
            if (strongSelf != nil && generation == strongSelf.launchGeneration) {
                [strongSelf consumeForwarderData:data];
            }
        });
    };
    task.terminationHandler = ^(NSTask *terminatedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SVCAppDelegate *strongSelf = weakSelf;
            [strongSelf forwarderDidTerminateWithStatus:terminatedTask.terminationStatus
                                                reason:terminatedTask.terminationReason
                                            generation:generation];
        });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        pipe.fileHandleForReading.readabilityHandler = nil;
        self.forwarderTask = nil;
        self.forwarderPipe = nil;
        self.errorDetail = error.localizedDescription;
        self.appState = SVCAppStateError;
        return NO;
    }
    [self scheduleAfterSeconds:SVC_APP_STARTUP_SECONDS action:^{
        SVCAppDelegate *strongSelf = weakSelf;
        [strongSelf forwarderStartupTimedOutForGeneration:generation];
    }];
    return YES;
}

- (void)scheduleAfterSeconds:(NSTimeInterval)seconds action:(dispatch_block_t)action {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), action);
}

- (void)launchAfterDelay:(NSTimeInterval)delay
         waitingForTask:(NSTask *)previousTask
             generation:(NSUInteger)generation {
    __weak SVCAppDelegate *weakSelf = self;
    [self scheduleAfterSeconds:delay action:^{
        SVCAppDelegate *strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf.launchGeneration
            || strongSelf.quitting) {
            return;
        }
        // A timed-out helper may still be finishing a blocking system call.
        // Wait for it to exit so a replacement cannot compete for its reader.
        if (previousTask.running) {
            [strongSelf launchAfterDelay:1 waitingForTask:previousTask
                             generation:generation];
            return;
        }
        if (![strongSelf launchForwarder]) {
            os_log_error(OS_LOG_DEFAULT, "SoundVolumeControl: audio startup failed: %{public}@",
                         strongSelf.errorDetail);
        }
    }];
}

- (void)retryForwarderStartup {
    NSTask *previousTask = self.forwarderTask != nil
        ? self.forwarderTask : self.stoppingForwarderTask;
    NSUInteger previousDelay = self.startupRetryDelay;
    NSString *detail = nil;
    BOOL restored = [self restorePhysicalDefaults:&detail];
    [self stopForwarder];
    if (!restored) {
        self.errorDetail = detail.length > 0 ? detail : @"The physical output could not be restored.";
        self.appState = SVCAppStateError;
        os_log_error(OS_LOG_DEFAULT, "SoundVolumeControl: startup retry stopped; physical output restoration failed");
        return;
    }
    self.startingPhysicalDefaultUID = [self currentPhysicalDefaultUID];
    self.startupRetryDelay = previousDelay == 0 ? 1 : MIN(previousDelay * 2, 15);
    self.startupRetryPending = YES;
    self.appState = SVCAppStateStarting;
    os_log_info(OS_LOG_DEFAULT, "SoundVolumeControl: retrying audio helper in %{public}lu seconds: %{public}@",
                (unsigned long)self.startupRetryDelay, self.errorDetail);
    [self launchAfterDelay:self.startupRetryDelay waitingForTask:previousTask
               generation:self.launchGeneration];
}

- (void)forwarderDidTerminateWithStatus:(int)status
                               reason:(NSTaskTerminationReason)reason
                           generation:(NSUInteger)generation {
    if (generation != self.launchGeneration) return;
    self.forwarderPipe.fileHandleForReading.readabilityHandler = nil;
    self.forwarderTask = nil;
    self.forwarderPipe = nil;
    if (self.quitting) return;
    // The helper can exit before either its final log or the Core Audio
    // notification reaches the main queue. Recover the new route either way.
    [self defaultDevicesDidChange];
    if (generation != self.launchGeneration) return;
    if ((!self.forwarderReady && reason == NSTaskTerminationReasonExit && status == EX_TEMPFAIL)
        || (self.forwarderReady && reason == NSTaskTerminationReasonUncaughtSignal)) {
        if (self.errorDetail.length == 0) {
            self.errorDetail = [NSString stringWithFormat:@"Audio helper stopped (status %d).", status];
        }
        [self retryForwarderStartup];
        return;
    }
    [self stopForwarder];
    if (self.errorDetail.length == 0) {
        self.errorDetail = [NSString stringWithFormat:
            @"Audio helper stopped (status %d).", status];
    }
    os_log_error(OS_LOG_DEFAULT, "SoundVolumeControl: audio helper stopped with terminal status %{public}d", status);
    self.appState = SVCAppStateError;
    (void)[self restorePhysicalDefaults:NULL];
    self.startingPhysicalDefaultUID = [self currentPhysicalDefaultUID];
}

- (void)forwarderStartupTimedOutForGeneration:(NSUInteger)generation {
    if (generation != self.launchGeneration || self.quitting
        || self.appState == SVCAppStateForwarding) {
        return;
    }
    self.errorDetail = @"Audio startup timed out.";
    [self retryForwarderStartup];
}

- (void)consumeForwarderData:(NSData *)data {
    NSUInteger generation = self.launchGeneration;
    [self.lineBuffer appendData:data];
    while (true) {
        const unsigned char *bytes = self.lineBuffer.bytes;
        NSUInteger length = self.lineBuffer.length;
        NSUInteger newline = NSNotFound;
        for (NSUInteger index = 0; index < length; ++index) {
            if (bytes[index] == '\n') {
                newline = index;
                break;
            }
        }
        if (newline == NSNotFound) {
            break;
        }
        NSData *lineData = [self.lineBuffer subdataWithRange:
            NSMakeRange(0, newline)];
        [self.lineBuffer replaceBytesInRange:NSMakeRange(0, newline + 1)
                                    withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData
                                               encoding:NSUTF8StringEncoding];
        [self consumeForwarderLine:[line
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        if (generation != self.launchGeneration) {
            [self.lineBuffer setLength:0];
            break;
        }
    }
}

- (void)consumeForwarderLine:(NSString *)line {
    if ([line isEqualToString:@"Forwarder ready."]) {
        if (!self.quitting && !self.forwarderReady
            && self.appState == SVCAppStateStarting) {
            NSUInteger generation = self.launchGeneration;
            [self defaultDevicesDidChange];
            if (generation != self.launchGeneration) return;
            if ([self volumeSupportForOutputUID:self.physicalOutputUID] != SVCVolumeSupportFixed) {
                [self restartForwarder:nil];
                return;
            }
            NSString *detail = nil;
            if (![self selectSoundVolumeWithDetail:&detail]) {
                (void)[self restorePhysicalDefaults:NULL];
                [self stopForwarder];
                self.startingPhysicalDefaultUID = [self currentPhysicalDefaultUID];
                self.errorDetail = detail;
                self.appState = SVCAppStateError;
                os_log_error(OS_LOG_DEFAULT, "SoundVolumeControl: virtual output selection failed: %{public}@", detail);
            } else {
                self.forwarderReady = YES;
            }
        }
    } else if (self.forwarderReady && [line isEqualToString:@"Forwarding is active."]) {
        self.startupRetryDelay = 0;
        self.appState = SVCAppStateForwarding;
    } else if ([line containsString:@"no longer selected"]) {
        [self defaultDevicesDidChange];
    } else if ([line containsString:@"failed:"]
               || [line hasPrefix:@"No eligible"]
               || [line containsString:@"is not installed"]
               || [line containsString:@"mismatch:"]) {
        self.errorDetail = line;
        // The exit status decides whether a startup error is transient. Keep
        // startup state until then so device notifications cannot interrupt a
        // pending retry merely because the physical output is still selected.
        if (self.forwarderReady) self.appState = SVCAppStateError;
    }
}

- (void)stopForwarder {
    if (self.startupRetryPending) {
        os_log_info(OS_LOG_DEFAULT, "SoundVolumeControl: pending audio startup retry cancelled");
    }
    ++self.launchGeneration;
    self.startupRetryDelay = 0;
    self.startupRetryPending = NO;
    self.forwarderReady = NO;
    self.forwarderPipe.fileHandleForReading.readabilityHandler = nil;
    NSTask *task = self.forwarderTask;
    self.forwarderTask = nil;
    self.forwarderPipe = nil;
    if (task.running) {
        self.stoppingForwarderTask = task;
        [task terminate];
    } else if (!self.stoppingForwarderTask.running) {
        self.stoppingForwarderTask = nil;
    }
}

- (void)restartForwarder:(id)sender {
    (void)sender;
    [self restartForwarderForDefaultChange:NO];
}

- (void)restartForwarderForDefaultChange:(BOOL)defaultChanged {
    if (self.quitting) {
        return;
    }
    NSString *detail = nil;
    if (![self restorePhysicalDefaults:&detail]) {
        // A failed menu change must keep the current helper alive while Sound
        // Volume may still be the normal output. An external change has already
        // selected a real output, so cancel that failed recovery completely.
        if (defaultChanged) {
            self.startingPhysicalDefaultUID = [self currentPhysicalDefaultUID];
            [self stopForwarder];
            self.errorDetail = detail;
            self.appState = SVCAppStateError;
        }
        os_log_error(OS_LOG_DEFAULT, "SoundVolumeControl: output change failed: %{public}@", detail);
        return;
    }
    NSTask *previousTask = self.forwarderTask != nil
        ? self.forwarderTask : self.stoppingForwarderTask;
    [self stopForwarder];
    self.physicalOutputUID = nil;
    NSString *physicalUID = nil;
    if (![self prepareOutputForForwarding:&physicalUID detail:&detail]) {
        self.errorDetail = detail;
        self.appState = SVCAppStateError;
        os_log_error(OS_LOG_DEFAULT, "SoundVolumeControl: output change failed: %{public}@", detail);
        return;
    }
    if (physicalUID == nil) return;
    self.appState = SVCAppStateStarting;
    [self launchAfterDelay:1.5 waitingForTask:previousTask generation:self.launchGeneration];
}

- (void)selectPhysicalOutput:(NSMenuItem *)sender {
    NSString *uid = [sender.representedObject isKindOfClass:NSString.class]
        ? sender.representedObject : @"";
    [[NSUserDefaults standardUserDefaults] setObject:uid
                                              forKey:@"physicalDeviceUID"];
    [self restartForwarder:nil];
    [self rebuildPhysicalOutputMenu];
}

- (BOOL)selectSoundVolumeWithDetail:(NSString **)outDetail {
    [self capturePhysicalDefaults];
    AudioDeviceID device = SVCDeviceForUID(@SVC_DEVICE_UID);
    if (device == kAudioObjectUnknown) {
        if (outDetail != NULL) {
            *outDetail = @"Install or restart the SoundVolumeControl audio driver first.";
        }
        return NO;
    }
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress output = SVCAddress(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal
    );
    AudioObjectPropertyAddress system = SVCAddress(
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal
    );
    OSStatus outputStatus = AudioObjectSetPropertyData(
        kAudioObjectSystemObject, &output, 0, NULL, size, &device
    );
    OSStatus systemStatus = AudioObjectSetPropertyData(
        kAudioObjectSystemObject, &system, 0, NULL, size, &device
    );
    if (outputStatus != noErr || systemStatus != noErr) {
        (void)[self restorePhysicalDefaults:NULL];
        if (outDetail != NULL) {
            *outDetail = @"macOS rejected the default-output change.";
        }
        return NO;
    }
    if (SVCDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice) != device
        || SVCDefaultDevice(
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ) != device) {
        (void)[self restorePhysicalDefaults:NULL];
        if (outDetail != NULL) {
            *outDetail = @"macOS did not keep Sound Volume selected.";
        }
        return NO;
    }
    return YES;
}

- (void)registerDefaultLoginItem {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"didSetDefaultLoginItem"]) return;

    // Register once so future launches honor changes made in Login Items.
    [defaults setBool:YES forKey:@"didSetDefaultLoginItem"];
    SMAppService *service = SMAppService.mainAppService;
    if (service.status == SMAppServiceStatusNotRegistered) {
        NSError *error = nil;
        if (![service registerAndReturnError:&error]) {
            os_log_error(OS_LOG_DEFAULT, "SoundVolumeControl: login item registration failed: %{public}@",
                         error.localizedDescription);
        }
    }
}

- (void)toggleStartAtLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL success = NO;
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
        [self updateLoginMenu];
        return;
    }
    if (service.status == SMAppServiceStatusEnabled) {
        success = [service unregisterAndReturnError:&error];
    } else {
        success = [service registerAndReturnError:&error];
    }
    if (!success && error != nil) {
        [self showErrorWithTitle:@"Start at Login could not be changed"
                         detail:error.localizedDescription];
    }
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    }
    [self updateLoginMenu];
}

- (void)showAbout:(id)sender {
    (void)sender;
    [NSApp orderFrontStandardAboutPanel:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showErrorWithTitle:(NSString *)title detail:(NSString *)detail {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = detail;
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2
            && strcmp(argv[1], "--login-item-status") == 0) {
            printf("%ld\n", (long)SMAppService.mainAppService.status);
            return 0;
        }
        if (argc == 2
            && strcmp(argv[1], "--register-login-item") == 0) {
            SMAppService *service = SMAppService.mainAppService;
            if (service.status == SMAppServiceStatusEnabled
                || service.status == SMAppServiceStatusRequiresApproval) {
                return 0;
            }
            NSError *error = nil;
            if (![service registerAndReturnError:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            return 0;
        }
        if (argc == 2
            && strcmp(argv[1], "--unregister-login-item") == 0) {
            SMAppService *service = SMAppService.mainAppService;
            if (service.status == SMAppServiceStatusNotRegistered
                || service.status == SMAppServiceStatusNotFound) {
                return 0;
            }
            NSError *error = nil;
            if (![service unregisterAndReturnError:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            return 0;
        }
        NSApplication *application = [NSApplication sharedApplication];
        SVCAppDelegate *delegate = [[SVCAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
