// Exercise menu route decisions without launching the app or touching CoreAudio.
#define main SVCMenuAppMain
#include "../app/main.m"
#undef main
#import <objc/runtime.h>
#include <assert.h>

static NSUserDefaults *testDefaults;
static id TestStandardDefaults(id self, SEL selector) {
    (void)self;
    (void)selector;
    return testDefaults;
}

@interface SVCTestDelegate : SVCAppDelegate
@property BOOL routeSucceeds;
@property NSUInteger selections;
@property NSUInteger restorations;
@property NSUInteger stops;
@property NSUInteger alerts;
@property(nonatomic, copy) NSString *mockPhysicalDefaultUID;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *mockVolumeSupport;
@property BOOL mockNoSoundVolumeOutput;
@property NSUInteger directSelections;
@property(nonatomic, copy) NSString *directPhysicalUID;
@end

@implementation SVCTestDelegate
- (void)updatePresentation {}
- (void)capturePhysicalDefaults {}
- (void)removeDefaultDeviceListeners {}
- (void)rebuildPhysicalOutputMenu {}
- (NSString *)currentPhysicalDefaultUID { return self.mockPhysicalDefaultUID; }
- (BOOL)soundVolumeIsDefaultOutput {
    return self.mockPhysicalDefaultUID == nil && !self.mockNoSoundVolumeOutput;
}
- (SVCVolumeSupport)volumeSupportForOutputUID:(NSString *)uid {
    NSNumber *support = self.mockVolumeSupport[uid == nil ? @"" : uid];
    return support == nil ? SVCVolumeSupportFixed : support.integerValue;
}
- (BOOL)selectDirectOutputWithUID:(NSString *)uid detail:(NSString **)detail {
    ++self.directSelections;
    self.directPhysicalUID = uid;
    if (detail != NULL) *detail = @"test direct route failure";
    if (self.routeSucceeds) self.mockPhysicalDefaultUID = uid;
    return self.routeSucceeds;
}
- (BOOL)selectSoundVolumeWithDetail:(NSString **)detail {
    ++self.selections;
    if (detail != NULL) *detail = @"test route failure";
    if (self.routeSucceeds) self.mockPhysicalDefaultUID = nil;
    return self.routeSucceeds;
}
- (BOOL)restorePhysicalDefaults:(NSString **)detail {
    ++self.restorations;
    if (detail != NULL) *detail = @"test restore failure";
    return self.routeSucceeds;
}
- (void)stopForwarder {
    ++self.stops;
    [super stopForwarder];
}
- (void)showErrorWithTitle:(NSString *)title detail:(NSString *)detail {
    (void)title;
    (void)detail;
    ++self.alerts;
}
@end

// Model helper exits and the scheduler without launching processes, changing
// audio devices, or waiting through repeated cold-start deadlines.
@interface SVCRetryTestDelegate : SVCTestDelegate
@property NSUInteger launches;
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *scheduled;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *delays;
@property(nonatomic, copy) NSString *launchedPhysicalUID;
- (void)runNextScheduled;
@end

@implementation SVCRetryTestDelegate
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        self.scheduled = [NSMutableArray array];
        self.delays = [NSMutableArray array];
        self.lineBuffer = [NSMutableData data];
        self.routeSucceeds = YES;
    }
    return self;
}
- (BOOL)launchForwarder {
    if (self.stoppingForwarderTask.running) return [super launchForwarder];
    NSString *physicalUID = nil;
    if (![self prepareOutputForForwarding:&physicalUID detail:NULL]) return NO;
    if (physicalUID == nil) return YES;
    ++self.launches;
    ++self.launchGeneration;
    self.forwarderReady = NO;
    self.startupRetryPending = NO;
    self.errorDetail = nil;
    self.appState = SVCAppStateStarting;
    self.startingPhysicalDefaultUID = [self currentPhysicalDefaultUID];
    self.launchedPhysicalUID = physicalUID;
    self.physicalOutputUID = physicalUID;
    return YES;
}
- (void)scheduleAfterSeconds:(NSTimeInterval)seconds action:(dispatch_block_t)action {
    [self.delays addObject:@(seconds)];
    [self.scheduled addObject:[action copy]];
}
- (void)runNextScheduled {
    assert(self.scheduled.count > 0);
    dispatch_block_t action = self.scheduled[0];
    [self.scheduled removeObjectAtIndex:0];
    action();
}
@end

@interface SVCStoppingTestTask : NSTask
@property BOOL active;
@property NSUInteger terminations;
@end
@implementation SVCStoppingTestTask
- (BOOL)isRunning { return self.active; }
- (void)terminate { ++self.terminations; }
@end

static SVCRetryTestDelegate *StartRetryFixture(void) {
    [testDefaults setBool:YES forKey:@"forwardingEnabled"];
    [testDefaults setObject:@"" forKey:@"physicalDeviceUID"];
    SVCRetryTestDelegate *delegate = [SVCRetryTestDelegate new];
    delegate.mockPhysicalDefaultUID = @"fixed-output";
    assert([delegate launchForwarder]);
    return delegate;
}

static void TemporaryStartupExit(SVCRetryTestDelegate *delegate) {
    [delegate consumeForwarderLine:@"Driver buffer failed: Operation timed out (60)."];
    [delegate forwarderDidTerminateWithStatus:EX_TEMPFAIL
                                      reason:NSTaskTerminationReasonExit
                                  generation:delegate.launchGeneration];
}

static void TestColdStartupRecovery(void) {
    SVCRetryTestDelegate *delegate = StartRetryFixture();
    NSArray<NSNumber *> *expectedDelays = @[@1, @2, @4, @8, @15, @15, @15, @15];
    for (NSNumber *delay in expectedDelays) {
        TemporaryStartupExit(delegate);
        assert([delegate forwardingEnabled]);
        assert(delegate.appState == SVCAppStateStarting);
        assert(delegate.startupRetryPending);
        assert([delegate.errorDetail containsString:@"(60)"]);
        assert(delegate.selections == 0);
        assert([delegate.delays.lastObject isEqual:delay]);
        [delegate runNextScheduled];
    }
    assert(delegate.launches == expectedDelays.count + 1);
    assert(delegate.restorations == expectedDelays.count);
    [delegate consumeForwarderLine:@"Forwarder ready."];
    assert(delegate.selections == 1 && delegate.forwarderReady);
    assert(delegate.startupRetryDelay == 0);
    [delegate consumeForwarderLine:@"Forwarding is active."];
    assert(delegate.appState == SVCAppStateForwarding);
    [delegate forwarderStartupTimedOutForGeneration:delegate.launchGeneration];
    assert(delegate.scheduled.count == 0);

    // A transient exit code after readiness cannot restart a revoked session.
    [delegate consumeForwarderLine:@"Audio broker failed: connection revoked."];
    assert(delegate.appState == SVCAppStateError);
    [delegate forwarderDidTerminateWithStatus:EX_TEMPFAIL
                                      reason:NSTaskTerminationReasonExit
                                  generation:delegate.launchGeneration];
    assert(![delegate forwardingEnabled] && delegate.scheduled.count == 0);
}

static void TestRetryCancellation(void) {
    SVCRetryTestDelegate *delegate = StartRetryFixture();
    TemporaryStartupExit(delegate);
    [delegate toggleForwarding:nil];
    [delegate runNextScheduled];
    assert(![delegate forwardingEnabled] && delegate.launches == 1);

    delegate = StartRetryFixture();
    TemporaryStartupExit(delegate);
    [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:nil]];
    [delegate runNextScheduled];
    assert(delegate.quitting && delegate.launches == 1);

    delegate = StartRetryFixture();
    TemporaryStartupExit(delegate);
    NSMenuItem *output = [NSMenuItem new];
    output.representedObject = @"replacement-output";
    [delegate selectPhysicalOutput:output];
    [delegate runNextScheduled]; // Cancelled retry for the old selection.
    assert(delegate.launches == 1);
    [delegate runNextScheduled]; // Explicit restart uses the new selection.
    assert(delegate.launches == 2);
    assert([delegate.launchedPhysicalUID isEqualToString:@"replacement-output"]);
}

static void TestWatchdogAndFailureBoundaries(void) {
    SVCRetryTestDelegate *delegate = StartRetryFixture();
    SVCStoppingTestTask *task = [SVCStoppingTestTask new];
    task.active = YES;
    delegate.forwarderTask = task;
    NSUInteger oldGeneration = delegate.launchGeneration;
    [delegate forwarderStartupTimedOutForGeneration:oldGeneration];
    assert(task.terminations == 1 && [delegate forwardingEnabled]);
    assert(delegate.restorations == 1 && delegate.selections == 0);
    [delegate forwarderDidTerminateWithStatus:EX_TEMPFAIL
                                      reason:NSTaskTerminationReasonExit
                                  generation:oldGeneration];
    assert(delegate.scheduled.count == 1); // Stale termination cannot duplicate retries.
    [delegate runNextScheduled];
    assert(delegate.launches == 1 && delegate.scheduled.count == 1);
    task.active = NO;
    [delegate runNextScheduled];
    assert(delegate.launches == 2);
    [delegate forwarderStartupTimedOutForGeneration:oldGeneration];
    assert(delegate.scheduled.count == 0); // Old watchdog cannot stop its replacement.

    delegate = StartRetryFixture();
    task = [SVCStoppingTestTask new];
    task.active = YES;
    delegate.forwarderTask = task;
    [delegate restartForwarder:nil];
    [delegate runNextScheduled];
    assert(delegate.launches == 1 && task.terminations == 1);
    task.active = NO;
    [delegate runNextScheduled];
    assert(delegate.launches == 2); // Output changes also await reader cleanup.

    delegate = StartRetryFixture();
    task = [SVCStoppingTestTask new];
    task.active = YES;
    delegate.forwarderTask = task;
    [delegate forwarderStartupTimedOutForGeneration:delegate.launchGeneration];
    assert(delegate.stoppingForwarderTask == task);
    NSMenuItem *output = [NSMenuItem new];
    output.representedObject = @"changed-during-watchdog";
    [delegate selectPhysicalOutput:output];
    [delegate runNextScheduled]; // Cancelled watchdog retry.
    [delegate runNextScheduled]; // New output still awaits the original helper.
    assert(delegate.launches == 1 && delegate.scheduled.count == 1);
    task.active = NO;
    [delegate runNextScheduled];
    assert(delegate.launches == 2);
    assert([delegate.launchedPhysicalUID isEqualToString:@"changed-during-watchdog"]);

    delegate = StartRetryFixture();
    task = [SVCStoppingTestTask new];
    task.active = YES;
    delegate.forwarderTask = task;
    [delegate forwarderStartupTimedOutForGeneration:delegate.launchGeneration];
    [delegate toggleForwarding:nil]; // Disable cancels retry but retains cleanup.
    [delegate toggleForwarding:nil]; // Enable must still wait for that helper.
    [delegate runNextScheduled]; // Cancelled watchdog retry.
    [delegate runNextScheduled]; // New Enable waits rather than competing.
    assert(delegate.launches == 1 && delegate.scheduled.count == 1);
    task.active = NO;
    [delegate runNextScheduled];
    assert(delegate.launches == 2 && [delegate forwardingEnabled]);

    delegate = StartRetryFixture();
    delegate.routeSucceeds = NO;
    [delegate forwarderStartupTimedOutForGeneration:delegate.launchGeneration];
    assert(![delegate forwardingEnabled] && delegate.scheduled.count == 0);
    assert([delegate.errorDetail isEqualToString:@"test restore failure"]);

    delegate = StartRetryFixture();
    [delegate consumeForwarderLine:@"Forwarder ready."];
    [delegate forwarderStartupTimedOutForGeneration:delegate.launchGeneration];
    assert(![delegate forwardingEnabled] && delegate.scheduled.count == 0);

    for (NSNumber *reason in @[@(NSTaskTerminationReasonExit), @(NSTaskTerminationReasonUncaughtSignal)]) {
        delegate = StartRetryFixture();
        NSUInteger generation = delegate.launchGeneration;
        [delegate forwarderDidTerminateWithStatus:reason.integerValue == NSTaskTerminationReasonExit ? 1 : EX_TEMPFAIL
                                          reason:reason.integerValue generation:generation];
        assert(![delegate forwardingEnabled] && delegate.scheduled.count == 0);
        assert(delegate.launchGeneration != generation);
    }
}

static SVCRetryTestDelegate *StartPhysicalFixture(BOOL ready) {
    [testDefaults setBool:YES forKey:@"forwardingEnabled"];
    [testDefaults setObject:@"first-output" forKey:@"physicalDeviceUID"];
    SVCRetryTestDelegate *delegate = [SVCRetryTestDelegate new];
    delegate.mockPhysicalDefaultUID = @"first-output";
    assert([delegate launchForwarder]);
    [delegate consumeForwarderLine:@"Physical output: First (first-output)"];
    if (ready) {
        [delegate consumeForwarderLine:@"Forwarder ready."];
        [delegate consumeForwarderLine:@"Forwarding is active."];
        assert(delegate.forwarderReady && delegate.selections == 1);
    }
    return delegate;
}

static void TestPhysicalOutputSwitching(void) {
    // The CoreAudio notification, helper message, and task exit can arrive in
    // any order. Each order must keep Enable intent and launch only one helper.
    for (NSUInteger firstEvent = 0; firstEvent < 3; ++firstEvent) {
        SVCRetryTestDelegate *delegate = StartPhysicalFixture(YES);
        NSUInteger oldGeneration = delegate.launchGeneration;
        delegate.mockPhysicalDefaultUID = @"second-output";
        if (firstEvent == 0) {
            [delegate defaultDevicesDidChange];
        } else if (firstEvent == 1) {
            [delegate consumeForwarderLine:
                @"Sound Volume is no longer selected; stopping physical IO."];
        } else {
            [delegate forwarderDidTerminateWithStatus:0
                                              reason:NSTaskTerminationReasonExit
                                          generation:oldGeneration];
        }
        [delegate defaultDevicesDidChange];
        [delegate consumeForwarderLine:
            @"Sound Volume is no longer selected; stopping physical IO."];
        [delegate forwarderDidTerminateWithStatus:0
                                          reason:NSTaskTerminationReasonExit
                                      generation:oldGeneration];
        assert([delegate forwardingEnabled]);
        assert(delegate.appState == SVCAppStateStarting);
        assert(delegate.launchGeneration != oldGeneration);
        assert(delegate.scheduled.count == 1 && delegate.launches == 1);
        assert([delegate.selectedPhysicalUID isEqualToString:@""]);
        assert(delegate.physicalOutputName.length == 0);
        assert(delegate.physicalOutputUID.length == 0);
        [delegate runNextScheduled];
        assert(delegate.launches == 2);
        assert([delegate.launchedPhysicalUID isEqualToString:@"second-output"]);
        [delegate consumeForwarderLine:@"Physical output: Second (second-output)"];
        [delegate consumeForwarderLine:@"Forwarder ready."];
        [delegate consumeForwarderLine:@"Forwarding is active."];
        assert(delegate.selections == 2 && delegate.forwarderReady);
        assert(delegate.appState == SVCAppStateForwarding);
    }
}

static void TestSwitchingDuringStartup(void) {
    for (NSNumber *waiting in @[@NO, @YES]) {
        SVCRetryTestDelegate *delegate = StartPhysicalFixture(NO);
        if (waiting.boolValue) {
            [delegate consumeForwarderLine:
                @"Waiting for Sound Volume to become the macOS output."];
        }
        [delegate defaultDevicesDidChange];
        assert(delegate.scheduled.count == 0); // The initial physical route.
        delegate.mockPhysicalDefaultUID = @"second-output";
        [delegate defaultDevicesDidChange];
        [delegate defaultDevicesDidChange];
        assert([delegate forwardingEnabled] && delegate.selections == 0);
        assert(delegate.scheduled.count == 1 && delegate.launches == 1);
        [delegate runNextScheduled];
        assert([delegate.launchedPhysicalUID isEqualToString:@"second-output"]);
        [delegate consumeForwarderLine:@"Forwarder ready."];
        [delegate consumeForwarderLine:@"Forwarding is active."];
        assert(delegate.selections == 1 && delegate.appState == SVCAppStateForwarding);
    }

    // Once ready has selected the virtual route, selecting even the original
    // physical destination is a new change, before the active acknowledgement.
    for (NSNumber *waiting in @[@NO, @YES]) {
        SVCRetryTestDelegate *delegate = StartPhysicalFixture(NO);
        [delegate consumeForwarderLine:@"Forwarder ready."];
        if (waiting.boolValue) {
            [delegate consumeForwarderLine:
                @"Waiting for Sound Volume to become the macOS output."];
        }
        delegate.mockPhysicalDefaultUID = @"first-output";
        [delegate forwarderDidTerminateWithStatus:0
                                          reason:NSTaskTerminationReasonExit
                                      generation:delegate.launchGeneration];
        assert([delegate forwardingEnabled] && !delegate.forwarderReady);
        assert(delegate.scheduled.count == 1);
        [delegate runNextScheduled];
        assert(delegate.launches == 2);
        assert([delegate.launchedPhysicalUID isEqualToString:@"first-output"]);
    }

    // Readiness can reach the main queue before the device notification. Do
    // not select Sound Volume for the destination that was just superseded.
    SVCRetryTestDelegate *delegate = StartPhysicalFixture(NO);
    delegate.mockPhysicalDefaultUID = @"second-output";
    [delegate consumeForwarderData:[@"Forwarder ready.\nForwarding is active.\n"
        dataUsingEncoding:NSUTF8StringEncoding]];
    assert(delegate.selections == 0 && !delegate.forwarderReady);
    assert(delegate.appState == SVCAppStateStarting);
    assert(delegate.lineBuffer.length == 0 && delegate.scheduled.count == 1);
    [delegate defaultDevicesDidChange];
    assert(delegate.scheduled.count == 1);
    [delegate runNextScheduled];
    assert([delegate.launchedPhysicalUID isEqualToString:@"second-output"]);

    // A second selection while the restart is pending wins over the first.
    delegate = StartPhysicalFixture(YES);
    delegate.mockPhysicalDefaultUID = @"second-output";
    [delegate defaultDevicesDidChange];
    delegate.mockPhysicalDefaultUID = @"third-output";
    [delegate defaultDevicesDidChange];
    assert(delegate.scheduled.count == 2);
    [delegate runNextScheduled];
    assert(delegate.launches == 1);
    [delegate runNextScheduled];
    assert(delegate.launches == 2);
    assert([delegate.launchedPhysicalUID isEqualToString:@"third-output"]);
}

static void TestOutputSelectionAndDisable(void) {
    SVCRetryTestDelegate *delegate = StartPhysicalFixture(YES);
    [delegate defaultDevicesDidChange]; // Virtual/unknown is not a new target.
    assert(delegate.launches == 1 && delegate.scheduled.count == 0);
    [delegate toggleForwarding:nil];
    delegate.mockPhysicalDefaultUID = @"second-output";
    [delegate defaultDevicesDidChange]; // Includes Disable's restore notification.
    [delegate consumeForwarderLine:
        @"Sound Volume is no longer selected; stopping physical IO."];
    assert(![delegate forwardingEnabled]);
    assert(delegate.launches == 1 && delegate.scheduled.count == 0);

    NSMenuItem *output = [NSMenuItem new];
    output.representedObject = @"selected-output";
    [delegate selectPhysicalOutput:output];
    assert(![delegate forwardingEnabled] && delegate.appState == SVCAppStateDisabled);
    assert(delegate.launches == 1 && delegate.scheduled.count == 0);
    assert(delegate.selections == 1);
    assert([delegate.selectedPhysicalUID isEqualToString:@"selected-output"]);

    // Device selection preserves an intentional Disable, including Automatic.
    output.representedObject = @"";
    [delegate selectPhysicalOutput:output];
    assert(![delegate forwardingEnabled] && delegate.appState == SVCAppStateDisabled);
    assert(delegate.launches == 1 && delegate.scheduled.count == 0);
    assert(delegate.selections == 1);
    assert([delegate.selectedPhysicalUID isEqualToString:@""]);

    [delegate toggleForwarding:nil]; // Explicit Enable uses the latest selection.
    assert([delegate forwardingEnabled] && delegate.launches == 2);
    assert([delegate.launchedPhysicalUID isEqualToString:@"second-output"]);

    [delegate toggleForwarding:nil];
    output.representedObject = @"latest-selected-output";
    [delegate selectPhysicalOutput:output];
    assert(![delegate forwardingEnabled] && delegate.launches == 2);
    assert(delegate.scheduled.count == 0 && delegate.selections == 1);
    [delegate toggleForwarding:nil];
    assert([delegate forwardingEnabled] && delegate.launches == 3);
    assert([delegate.launchedPhysicalUID isEqualToString:@"latest-selected-output"]);

    delegate = StartPhysicalFixture(YES);
    [delegate applicationWillTerminate:[NSNotification
        notificationWithName:NSApplicationWillTerminateNotification object:nil]];
    delegate.mockPhysicalDefaultUID = @"second-output";
    [delegate defaultDevicesDidChange];
    assert(delegate.quitting && delegate.launches == 1);
    assert(delegate.scheduled.count == 0);
}

static void TestSourceChangeFailureBoundaries(void) {
    // A menu change can fail while Sound Volume is still the normal route.
    // Keep the established helper alive until a physical route is restored.
    SVCRetryTestDelegate *menuDelegate = StartPhysicalFixture(YES);
    SVCStoppingTestTask *activeTask = [SVCStoppingTestTask new];
    activeTask.active = YES;
    menuDelegate.forwarderTask = activeTask;
    NSUInteger menuGeneration = menuDelegate.launchGeneration;
    menuDelegate.routeSucceeds = NO;
    NSMenuItem *output = [NSMenuItem new];
    output.representedObject = @"second-output";
    [menuDelegate selectPhysicalOutput:output];
    assert([menuDelegate forwardingEnabled] && menuDelegate.forwarderReady);
    assert(menuDelegate.appState == SVCAppStateForwarding);
    assert(menuDelegate.launchGeneration == menuGeneration);
    assert(menuDelegate.forwarderTask == activeTask && activeTask.running);
    assert(activeTask.terminations == 0 && menuDelegate.stops == 0);
    assert(menuDelegate.scheduled.count == 0 && menuDelegate.launches == 1);
    assert(menuDelegate.alerts == 1 && menuDelegate.restorations == 1);

    // An obsolete helper may fail before its ready acknowledgement. A new
    // physical destination still gets a fresh attempt instead of being disabled.
    for (NSNumber *reason in @[@(NSTaskTerminationReasonExit),
                               @(NSTaskTerminationReasonUncaughtSignal)]) {
        SVCRetryTestDelegate *delegate = StartPhysicalFixture(NO);
        delegate.mockPhysicalDefaultUID = @"second-output";
        [delegate consumeForwarderLine:@"AudioDeviceStart failed: old device removed"];
        [delegate forwarderDidTerminateWithStatus:1 reason:reason.integerValue
                                      generation:delegate.launchGeneration];
        assert([delegate forwardingEnabled] && delegate.selections == 0);
        assert(delegate.appState == SVCAppStateStarting);
        assert(delegate.scheduled.count == 1);
        [delegate runNextScheduled];
        assert(delegate.launches == 2 && delegate.errorDetail.length == 0);
        assert([delegate.launchedPhysicalUID isEqualToString:@"second-output"]);
    }

    // Failed restoration must invalidate readiness and stale buffered messages,
    // whether the switch is first noticed at readiness or at helper termination.
    for (NSNumber *terminating in @[@NO, @YES]) {
        SVCRetryTestDelegate *delegate = StartPhysicalFixture(terminating.boolValue);
        NSUInteger selections = delegate.selections;
        NSUInteger generation = delegate.launchGeneration;
        delegate.mockPhysicalDefaultUID = @"second-output";
        delegate.routeSucceeds = NO;
        if (terminating.boolValue) {
            [delegate forwarderDidTerminateWithStatus:0
                                              reason:NSTaskTerminationReasonExit
                                          generation:generation];
        } else {
            [delegate consumeForwarderData:[@"Forwarder ready.\nForwarding is active.\n"
                dataUsingEncoding:NSUTF8StringEncoding]];
        }
        assert(![delegate forwardingEnabled] && !delegate.forwarderReady);
        assert(delegate.appState == SVCAppStateError);
        assert(delegate.launchGeneration != generation);
        assert(delegate.selections == selections && delegate.stops == 1);
        assert(delegate.scheduled.count == 0 && delegate.lineBuffer.length == 0);
        assert([delegate.errorDetail isEqualToString:@"test restore failure"]);
        assert(delegate.alerts == 1);
        [delegate consumeForwarderLine:@"Forwarder ready."];
        assert(delegate.selections == selections);
        [delegate defaultDevicesDidChange];
        assert(delegate.scheduled.count == 0 && ![delegate forwardingEnabled]);
    }
}

static NSDictionary<NSString *, NSNumber *> *NativePolicySupport(void) {
    return @{
        @"native-output": @(SVCVolumeSupportNative),
        @"other-native-output": @(SVCVolumeSupportNative),
        @"fixed-output": @(SVCVolumeSupportFixed),
        @"unknown-output": @(SVCVolumeSupportUnknown),
    };
}

static void TestNativeLaunchAndSelection(void) {
    [testDefaults setBool:YES forKey:@"forwardingEnabled"];
    [testDefaults setObject:@"" forKey:@"physicalDeviceUID"];
    // Exercise the production launch preflight. A native output must return
    // before looking for or launching the bundled helper.
    SVCTestDelegate *delegate = [SVCTestDelegate new];
    delegate.routeSucceeds = YES;
    delegate.mockVolumeSupport = NativePolicySupport();
    delegate.mockPhysicalDefaultUID = @"native-output";
    assert([delegate launchForwarder]);
    assert([delegate forwardingEnabled]);
    assert(delegate.appState == SVCAppStateNativeVolume);
    assert(delegate.forwarderTask == nil && delegate.selections == 0);
    assert(delegate.directSelections == 0 && delegate.alerts == 0);
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"native-output"]);

    NSMenuItem *output = [NSMenuItem new];
    output.representedObject = @"other-native-output";
    [delegate selectPhysicalOutput:output];
    assert([delegate forwardingEnabled]);
    assert(delegate.appState == SVCAppStateNativeVolume);
    assert(delegate.directSelections == 1 && delegate.selections == 0);
    assert([delegate.directPhysicalUID isEqualToString:@"other-native-output"]);
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"other-native-output"]);
    NSUInteger generation = delegate.launchGeneration;
    [delegate defaultDevicesDidChange];
    assert(delegate.launchGeneration == generation && delegate.directSelections == 1);

    [delegate toggleForwarding:nil];
    delegate.mockPhysicalDefaultUID = @"fixed-output";
    [delegate defaultDevicesDidChange];
    output.representedObject = @"fixed-output";
    [delegate selectPhysicalOutput:output];
    assert(![delegate forwardingEnabled] && delegate.appState == SVCAppStateDisabled);
    assert(delegate.forwarderTask == nil && delegate.selections == 0);
    assert(delegate.directSelections == 1);
}

static void TestNativeAndFixedTransitions(void) {
    // Returning to native control cancels a pending launch, an established
    // helper, or its delayed startup retry without losing Enable intent.
    for (NSUInteger stage = 0; stage < 3; ++stage) {
        [testDefaults setBool:YES forKey:@"forwardingEnabled"];
        [testDefaults setObject:@"" forKey:@"physicalDeviceUID"];
        SVCRetryTestDelegate *delegate = [SVCRetryTestDelegate new];
        delegate.mockVolumeSupport = NativePolicySupport();
        delegate.mockPhysicalDefaultUID = @"native-output";
        assert([delegate launchForwarder]);
        assert(delegate.launches == 0 && delegate.appState == SVCAppStateNativeVolume);

        delegate.mockPhysicalDefaultUID = @"fixed-output";
        [delegate defaultDevicesDidChange];
        assert([delegate forwardingEnabled] && delegate.scheduled.count == 1);
        assert(delegate.appState == SVCAppStateStarting);
        SVCStoppingTestTask *activeTask = nil;
        if (stage > 0) {
            [delegate runNextScheduled];
            assert(delegate.launches == 1);
            assert([delegate.launchedPhysicalUID isEqualToString:@"fixed-output"]);
            if (stage == 1) {
                [delegate consumeForwarderLine:@"Forwarder ready."];
                [delegate consumeForwarderLine:@"Forwarding is active."];
                activeTask = [SVCStoppingTestTask new];
                activeTask.active = YES;
                delegate.forwarderTask = activeTask;
            } else {
                TemporaryStartupExit(delegate);
                assert(delegate.startupRetryPending && delegate.scheduled.count == 1);
            }
        }
        NSUInteger staleGeneration = delegate.launchGeneration;
        delegate.mockPhysicalDefaultUID = @"native-output";
        [delegate defaultDevicesDidChange];
        assert([delegate forwardingEnabled] && !delegate.forwarderReady);
        assert(delegate.appState == SVCAppStateNativeVolume);
        assert(delegate.launchGeneration != staleGeneration);
        assert(delegate.forwarderTask == nil && !delegate.startupRetryPending);
        if (activeTask != nil) assert(activeTask.terminations == 1);
        [delegate forwarderDidTerminateWithStatus:1
                                          reason:NSTaskTerminationReasonExit
                                      generation:staleGeneration];
        [delegate forwarderStartupTimedOutForGeneration:staleGeneration];
        while (delegate.scheduled.count > 0) [delegate runNextScheduled];
        assert(delegate.appState == SVCAppStateNativeVolume);
        assert([delegate forwardingEnabled] && delegate.launches == (stage == 0 ? 0 : 1));

        [delegate toggleForwarding:nil];
        delegate.mockPhysicalDefaultUID = @"fixed-output";
        [delegate defaultDevicesDidChange];
        assert(![delegate forwardingEnabled] && delegate.appState == SVCAppStateDisabled);
        assert(delegate.scheduled.count == 0);
    }
}

static void TestUnknownVolumeSupport(void) {
    [testDefaults setBool:YES forKey:@"forwardingEnabled"];
    [testDefaults setObject:@"" forKey:@"physicalDeviceUID"];
    SVCTestDelegate *missing = [SVCTestDelegate new];
    missing.routeSucceeds = YES;
    missing.mockNoSoundVolumeOutput = YES;
    missing.mockVolumeSupport = @{@"": @(SVCVolumeSupportUnknown)};
    assert([missing launchForwarder]);
    assert([missing forwardingEnabled] && missing.appState == SVCAppStateNoEligibleOutput);
    assert(missing.forwarderTask == nil && missing.selections == 0);

    SVCRetryTestDelegate *delegate = [SVCRetryTestDelegate new];
    delegate.mockVolumeSupport = NativePolicySupport();
    delegate.mockPhysicalDefaultUID = @"unknown-output";
    assert([delegate launchForwarder]);
    assert([delegate forwardingEnabled] && delegate.appState == SVCAppStateNoEligibleOutput);
    assert(delegate.launches == 0 && delegate.scheduled.count == 0);
    [delegate defaultDevicesDidChange];
    assert(delegate.launches == 0 && delegate.appState == SVCAppStateNoEligibleOutput);
    delegate.mockVolumeSupport = @{@"unknown-output": @(SVCVolumeSupportFixed)};
    [delegate defaultDevicesDidChange]; // Recheck a transient failure on the same UID.
    assert(delegate.scheduled.count == 1 && delegate.launches == 0);
    [delegate runNextScheduled];
    assert(delegate.launches == 1);
    assert([delegate.launchedPhysicalUID isEqualToString:@"unknown-output"]);

    // A retry on the unchanged physical default preserves an explicit choice
    // whose volume capabilities were temporarily unavailable.
    [testDefaults setObject:@"unknown-output" forKey:@"physicalDeviceUID"];
    delegate = [SVCRetryTestDelegate new];
    delegate.mockVolumeSupport = NativePolicySupport();
    delegate.mockPhysicalDefaultUID = @"native-output";
    assert([delegate launchForwarder]);
    assert(delegate.appState == SVCAppStateNoEligibleOutput);
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"native-output"]);
    delegate.mockVolumeSupport = @{@"unknown-output": @(SVCVolumeSupportFixed)};
    [delegate defaultDevicesDidChange];
    assert([delegate.selectedPhysicalUID isEqualToString:@"unknown-output"]);
    assert(delegate.scheduled.count == 1 && delegate.launches == 0);
    [delegate runNextScheduled];
    assert([delegate.launchedPhysicalUID isEqualToString:@"unknown-output"]);
}

static void TestCapabilityChangeBeforeReadiness(void) {
    for (NSNumber *support in @[@(SVCVolumeSupportNative), @(SVCVolumeSupportUnknown)]) {
        SVCRetryTestDelegate *delegate = StartPhysicalFixture(NO);
        delegate.mockVolumeSupport = @{@"first-output": support};
        [delegate consumeForwarderData:[@"Forwarder ready.\nForwarding is active.\n"
            dataUsingEncoding:NSUTF8StringEncoding]];
        assert([delegate forwardingEnabled] && !delegate.forwarderReady);
        assert(delegate.selections == 0 && delegate.scheduled.count == 0);
        assert(delegate.lineBuffer.length == 0);
        assert(delegate.appState == (support.integerValue == SVCVolumeSupportNative
            ? SVCAppStateNativeVolume : SVCAppStateNoEligibleOutput));
    }
}

int main(void) {
    @autoreleasepool {
        NSString *suite = [NSString stringWithFormat:
            @"org.soundvolumecontrol.tests.%d", getpid()];
        testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Method method = class_getClassMethod(NSUserDefaults.class,
                                              @selector(standardUserDefaults));
        IMP original = method_setImplementation(method, (IMP)TestStandardDefaults);
        [testDefaults setBool:YES forKey:@"forwardingEnabled"];
        SVCTestDelegate *delegate = [SVCTestDelegate new];
        delegate.lineBuffer = [NSMutableData data];
        delegate.routeSucceeds = YES;
        delegate.appState = SVCAppStateStarting;
        [delegate consumeForwarderLine:@"Physical output: Test (test-output)"];
        assert(delegate.selections == 0);
        [delegate consumeForwarderLine:@"Forwarder ready."];
        assert(delegate.selections == 1);
        [delegate consumeForwarderLine:@"Forwarding is active."];
        assert(delegate.appState == SVCAppStateForwarding);

        delegate.routeSucceeds = NO;
        [delegate consumeForwarderData:[@"Forwarder ready.\nForwarding is active.\n"
            dataUsingEncoding:NSUTF8StringEncoding]];
        assert(delegate.appState == SVCAppStateError);
        assert(delegate.restorations == 1 && delegate.stops == 1);
        assert(![delegate forwardingEnabled]);
        assert(delegate.lineBuffer.length == 0);
        [delegate consumeForwarderLine:@"Forwarder ready."];
        assert(delegate.selections == 2); // Disabled: no new route selection.

        // The delegate never messages sender; avoid starting NSApplication.
        NSApplication *sender = (NSApplication *)[NSObject new];
        assert([delegate applicationShouldTerminate:sender] == NSTerminateCancel);
        assert(delegate.alerts == 1);
        delegate.routeSucceeds = YES;
        assert([delegate applicationShouldTerminate:sender] == NSTerminateNow);
        assert(delegate.restorations == 3);

        TestColdStartupRecovery();
        TestRetryCancellation();
        TestWatchdogAndFailureBoundaries();
        TestPhysicalOutputSwitching();
        TestSwitchingDuringStartup();
        TestOutputSelectionAndDisable();
        TestSourceChangeFailureBoundaries();
        TestNativeLaunchAndSelection();
        TestNativeAndFixedTransitions();
        TestUnknownVolumeSupport();
        TestCapabilityChangeBeforeReadiness();

        [testDefaults removePersistentDomainForName:suite];
        method_setImplementation(method, original);
        puts("app-lifecycle-tests: PASS (native volume policy, late startup recovery, source switching, output selection, bounded backoff, cancellation, safe routing, ready handshake, stale output, safe Quit)");
    }
    return 0;
}
