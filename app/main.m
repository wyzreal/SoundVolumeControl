#import <AppKit/AppKit.h>
#import <CoreAudio/AudioHardware.h>
#import <ServiceManagement/ServiceManagement.h>

#include "SoundVolumeControlIDs.h"

#include <stdbool.h>

typedef NS_ENUM(NSInteger, SVCAppState) {
    SVCAppStateDisabled,
    SVCAppStateStarting,
    SVCAppStateWaiting,
    SVCAppStateForwarding,
    SVCAppStateError,
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
@property(nonatomic, strong) NSMenuItem *enabledMenuItem;
@property(nonatomic, strong) NSMenuItem *loginMenuItem;
@property(nonatomic, strong) NSMenuItem *outputMenuItem;
@property(nonatomic, strong) NSTask *forwarderTask;
@property(nonatomic, strong) NSPipe *forwarderPipe;
@property(nonatomic, strong) NSMutableData *lineBuffer;
@property(nonatomic, copy) NSString *physicalOutputName;
@property(nonatomic, copy) NSString *physicalOutputUID;
@property(nonatomic, copy) NSString *errorDetail;
@property(nonatomic, copy) NSString *lastPhysicalDefaultUID;
@property(nonatomic, copy) NSString *lastPhysicalSystemUID;
@property(nonatomic) SVCAppState appState;
@property(nonatomic) BOOL quitting;
@property(nonatomic) BOOL defaultOutputListenerInstalled;
@property(nonatomic) BOOL defaultSystemListenerInstalled;
@property(nonatomic) NSUInteger launchGeneration;
- (void)capturePhysicalDefaults;
- (void)defaultDevicesDidChange;
- (BOOL)launchForwarder;
- (BOOL)selectSoundVolumeWithDetail:(NSString **)outDetail;
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
        @"forwardingEnabled": @YES,
        @"physicalDeviceUID": @"",
        @"lastPhysicalDefaultUID": @"",
        @"lastPhysicalSystemUID": @"",
    }];
    // Disable and helper failures apply only to the current session. Every
    // launch, including Start at Login, should attempt to enable forwarding.
    [[NSUserDefaults standardUserDefaults]
        setBool:YES forKey:@"forwardingEnabled"];
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
    self.statusItem.button.toolTip = @"SoundVolumeControl";
    self.menu = [[NSMenu alloc] initWithTitle:@"SoundVolumeControl"];
    self.menu.delegate = self;
    self.statusItem.menu = self.menu;
    [self buildMenu];
    [self updatePresentation];

    if ([self forwardingEnabled]) {
        NSString *detail = nil;
        if (![self launchForwarder]) {
            detail = self.errorDetail.length > 0
                ? self.errorDetail : @"The audio helper could not be started.";
        }
        if (detail != nil) {
            [[NSUserDefaults standardUserDefaults]
                setBool:NO forKey:@"forwardingEnabled"];
            [self stopForwarder];
            self.appState = SVCAppStateDisabled;
            [self updatePresentation];
            [self showErrorWithTitle:@"Could not enable volume control"
                             detail:detail];
        }
    } else {
        self.appState = SVCAppStateDisabled;
        [self updatePresentation];
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
    ++self.launchGeneration;
    [self removeDefaultDeviceListeners];
    self.forwarderPipe.fileHandleForReading.readabilityHandler = nil;
    if (self.forwarderTask.running) {
        [self.forwarderTask terminate];
    }
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

- (void)capturePhysicalDefaults {
    AudioDeviceID output = SVCDefaultDevice(
        kAudioHardwarePropertyDefaultOutputDevice
    );
    if (SVCIsPhysicalOutput(output)) {
        NSString *uid = SVCCopyString(
            output,
            SVCAddress(kAudioDevicePropertyDeviceUID,
                       kAudioObjectPropertyScopeGlobal)
        );
        if (uid.length > 0) {
            self.lastPhysicalDefaultUID = uid;
            [[NSUserDefaults standardUserDefaults]
                setObject:uid forKey:@"lastPhysicalDefaultUID"];
        }
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
    if (self.quitting || ![self forwardingEnabled]) {
        return;
    }
    if (self.appState == SVCAppStateStarting
        || self.appState == SVCAppStateWaiting) {
        return;
    }
    AudioDeviceID virtualDevice = SVCDeviceForUID(@SVC_DEVICE_UID);
    AudioDeviceID currentOutput = SVCDefaultDevice(
        kAudioHardwarePropertyDefaultOutputDevice
    );
    if (virtualDevice != kAudioObjectUnknown
        && currentOutput != virtualDevice) {
        [[NSUserDefaults standardUserDefaults]
            setBool:NO forKey:@"forwardingEnabled"];
        (void)[self restorePhysicalDefaults:NULL];
        [self stopForwarder];
        self.appState = SVCAppStateDisabled;
        [self updatePresentation];
    }
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

- (BOOL)forwardingEnabled {
    return [[NSUserDefaults standardUserDefaults]
        boolForKey:@"forwardingEnabled"];
}

- (NSString *)selectedPhysicalUID {
    NSString *uid = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"physicalDeviceUID"];
    return uid == nil ? @"" : uid;
}

- (void)buildMenu {
    [self.menu removeAllItems];

    self.statusMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Starting…" action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [self.menu addItem:self.statusMenuItem];
    [self.menu addItem:[NSMenuItem separatorItem]];

    self.enabledMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Enable"
               action:@selector(toggleForwarding:)
        keyEquivalent:@""];
    self.enabledMenuItem.target = self;
    [self.menu addItem:self.enabledMenuItem];

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
    [self rebuildPhysicalOutputMenu];
    [self updatePresentation];
}

- (void)rebuildPhysicalOutputMenu {
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Output Device"];
    NSString *selectedUID = [self selectedPhysicalUID];

    NSString *automaticTitle = self.physicalOutputName.length > 0
        ? [NSString stringWithFormat:@"Automatic — %@", self.physicalOutputName]
        : @"Automatic";
    NSMenuItem *automatic = [[NSMenuItem alloc]
        initWithTitle:automaticTitle
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

- (void)updatePresentation {
    NSString *symbol = @"speaker.wave.2";
    NSString *status = @"Starting audio helper…";
    switch (self.appState) {
        case SVCAppStateDisabled:
            symbol = @"speaker.slash";
            status = @"Disabled";
            break;
        case SVCAppStateStarting:
            symbol = @"ellipsis.circle";
            status = @"Enabling…";
            break;
        case SVCAppStateWaiting:
            symbol = @"speaker.wave.2";
            status = @"Enabling…";
            break;
        case SVCAppStateForwarding:
            symbol = @"speaker.wave.3.fill";
            status = self.physicalOutputName.length > 0
                ? [NSString stringWithFormat:@"Enabled — %@",
                                             self.physicalOutputName]
                : @"Enabled";
            break;
        case SVCAppStateError:
            symbol = @"exclamationmark.triangle";
            status = self.errorDetail.length > 0
                ? [NSString stringWithFormat:@"Error — %@", self.errorDetail]
                : @"Audio helper error";
            break;
    }

    NSImage *image = [NSImage imageWithSystemSymbolName:symbol
                              accessibilityDescription:status];
    image.template = YES;
    self.statusItem.button.image = image;
    self.statusItem.button.title = @"";
    self.statusItem.button.toolTip = status;
    self.statusMenuItem.title = status;
    self.enabledMenuItem.title = [self forwardingEnabled]
        ? @"Disable" : @"Enable";
    self.enabledMenuItem.state = NSControlStateValueOff;

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
    if (self.quitting || ![self forwardingEnabled]) {
        return NO;
    }
    NSURL *helperURL = [[NSBundle mainBundle].bundleURL
        URLByAppendingPathComponent:
            @"Contents/Helpers/SoundVolumeForwarder.app/Contents/MacOS/"
             "SoundVolumeForwarder"];
    if (![[NSFileManager defaultManager]
            isExecutableFileAtPath:helperURL.path]) {
        self.errorDetail = @"bundled helper is missing";
        self.appState = SVCAppStateError;
        [self updatePresentation];
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = helperURL;
    NSString *physicalUID = [self selectedPhysicalUID];
    task.arguments = physicalUID.length > 0
        ? @[@"--physical-uid", physicalUID] : @[];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    self.forwarderTask = task;
    self.forwarderPipe = pipe;
    [self.lineBuffer setLength:0];
    self.errorDetail = nil;
    self.appState = SVCAppStateStarting;
    [self updatePresentation];

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
            if (strongSelf == nil || generation != strongSelf.launchGeneration) {
                return;
            }
            strongSelf.forwarderPipe.fileHandleForReading.readabilityHandler = nil;
            strongSelf.forwarderTask = nil;
            strongSelf.forwarderPipe = nil;
            if (strongSelf.quitting || ![strongSelf forwardingEnabled]) {
                return;
            }
            if (strongSelf.errorDetail.length == 0) {
                strongSelf.errorDetail = [NSString stringWithFormat:
                    @"Audio helper stopped (status %d). Volume control is disabled.",
                    terminatedTask.terminationStatus];
            }
            strongSelf.appState = SVCAppStateError;
            [[NSUserDefaults standardUserDefaults]
                setBool:NO forKey:@"forwardingEnabled"];
            (void)[strongSelf restorePhysicalDefaults:NULL];
            [strongSelf updatePresentation];
        });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        pipe.fileHandleForReading.readabilityHandler = nil;
        self.forwarderTask = nil;
        self.forwarderPipe = nil;
        self.errorDetail = error.localizedDescription;
        self.appState = SVCAppStateError;
        [self updatePresentation];
        return NO;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        SVCAppDelegate *strongSelf = weakSelf;
        if (strongSelf != nil && generation == strongSelf.launchGeneration
            && !strongSelf.quitting && [strongSelf forwardingEnabled]
            && strongSelf.appState != SVCAppStateForwarding) {
            [[NSUserDefaults standardUserDefaults]
                setBool:NO forKey:@"forwardingEnabled"];
            (void)[strongSelf restorePhysicalDefaults:NULL];
            [strongSelf stopForwarder];
            strongSelf.errorDetail = @"Audio startup timed out. Volume control is disabled.";
            strongSelf.appState = SVCAppStateError;
            [strongSelf updatePresentation];
        }
    });
    return YES;
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
    if ([line hasPrefix:@"Physical output: "]) {
        NSString *detail = [line substringFromIndex:@"Physical output: ".length];
        NSRange uidStart = [detail rangeOfString:@" (" options:NSBackwardsSearch];
        self.physicalOutputName = uidStart.location == NSNotFound
            ? detail : [detail substringToIndex:uidStart.location];
        if (uidStart.location != NSNotFound && [detail hasSuffix:@")"]) {
            NSUInteger start = NSMaxRange(uidStart);
            self.physicalOutputUID = [detail substringWithRange:NSMakeRange(
                start, detail.length - start - 1
            )];
        }
    } else if ([line isEqualToString:@"Forwarder ready."]) {
        if (!self.quitting && [self forwardingEnabled]) {
            NSString *detail = nil;
            if (![self selectSoundVolumeWithDetail:&detail]) {
                [[NSUserDefaults standardUserDefaults]
                    setBool:NO forKey:@"forwardingEnabled"];
                (void)[self restorePhysicalDefaults:NULL];
                [self stopForwarder];
                self.errorDetail = detail;
                self.appState = SVCAppStateError;
            }
        }
    } else if ([line containsString:@"Waiting for Sound Volume"]) {
        self.appState = SVCAppStateWaiting;
    } else if ([line containsString:@"Forwarding is active"]) {
        self.appState = SVCAppStateForwarding;
    } else if ([line containsString:@"no longer selected"]) {
        [[NSUserDefaults standardUserDefaults]
            setBool:NO forKey:@"forwardingEnabled"];
        (void)[self restorePhysicalDefaults:NULL];
        [self stopForwarder];
        self.appState = SVCAppStateDisabled;
    } else if ([line containsString:@"failed:"]
               || [line hasPrefix:@"No eligible"]
               || [line containsString:@"is not installed"]
               || [line containsString:@"mismatch:"]) {
        self.errorDetail = line;
        self.appState = SVCAppStateError;
    }
    [self updatePresentation];
}

- (void)stopForwarder {
    ++self.launchGeneration;
    self.forwarderPipe.fileHandleForReading.readabilityHandler = nil;
    NSTask *task = self.forwarderTask;
    self.forwarderTask = nil;
    self.forwarderPipe = nil;
    if (task.running) {
        [task terminate];
    }
}

- (void)restartForwarder:(id)sender {
    (void)sender;
    if (![self forwardingEnabled]) {
        return;
    }
    NSString *detail = nil;
    if (![self restorePhysicalDefaults:&detail]) {
        [self showErrorWithTitle:@"Could not change audio output" detail:detail];
        return;
    }
    [self stopForwarder];
    self.appState = SVCAppStateStarting;
    [self updatePresentation];
    NSUInteger generation = self.launchGeneration;
    __weak SVCAppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(1500 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        SVCAppDelegate *strongSelf = weakSelf;
        if (strongSelf != nil
            && generation == strongSelf.launchGeneration
            && !strongSelf.quitting
            && [strongSelf forwardingEnabled]) {
            if (![strongSelf launchForwarder]) {
                [[NSUserDefaults standardUserDefaults]
                    setBool:NO forKey:@"forwardingEnabled"];
            }
        }
    });
}

- (void)toggleForwarding:(id)sender {
    (void)sender;
    if (![self forwardingEnabled]) {
        [[NSUserDefaults standardUserDefaults]
            setBool:YES forKey:@"forwardingEnabled"];
        NSString *detail = nil;
        if (![self launchForwarder]) {
            detail = self.errorDetail.length > 0
                ? self.errorDetail : @"The audio helper could not be started.";
        }
        if (detail != nil) {
            [[NSUserDefaults standardUserDefaults]
                setBool:NO forKey:@"forwardingEnabled"];
            [self stopForwarder];
            self.appState = SVCAppStateDisabled;
            [self updatePresentation];
            [self showErrorWithTitle:@"Could not enable volume control"
                             detail:detail];
        }
    } else {
        [[NSUserDefaults standardUserDefaults]
            setBool:NO forKey:@"forwardingEnabled"];
        NSString *detail = nil;
        if (![self restorePhysicalDefaults:&detail]) {
            [self showErrorWithTitle:@"Volume control remains enabled"
                             detail:detail];
            [[NSUserDefaults standardUserDefaults]
                setBool:YES forKey:@"forwardingEnabled"];
            return;
        }
        [self stopForwarder];
        self.appState = SVCAppStateDisabled;
        [self updatePresentation];
    }
}

- (void)selectPhysicalOutput:(NSMenuItem *)sender {
    NSString *uid = [sender.representedObject isKindOfClass:NSString.class]
        ? sender.representedObject : @"";
    [[NSUserDefaults standardUserDefaults] setObject:uid
                                              forKey:@"physicalDeviceUID"];
    self.physicalOutputName = nil;
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

- (void)toggleStartAtLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL success = NO;
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
        [self updatePresentation];
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
    [self updatePresentation];
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
