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
@property(nonatomic, copy) NSString *mockRestoredOutputUID;
@property(nonatomic, copy) NSArray<NSString *> *mockOutputUIDs;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *mockVolumeSupport;
@property BOOL mockNoSoundVolumeOutput;
@property NSUInteger directSelections;
@property(nonatomic, copy) NSString *directPhysicalUID;
@end

@implementation SVCTestDelegate
- (void)capturePhysicalDefaults {}
- (void)removeDefaultDeviceListeners {}
- (void)rebuildPhysicalOutputMenu {}
- (NSArray<NSDictionary<NSString *, id> *> *)physicalOutputs {
    if (self.mockOutputUIDs == nil) return nil;
    NSMutableArray *outputs = [NSMutableArray array];
    for (NSString *uid in self.mockOutputUIDs) {
        [outputs addObject:@{@"uid": uid, @"name": uid}];
    }
    return outputs;
}
- (NSString *)currentPhysicalDefaultUID { return self.mockPhysicalDefaultUID; }
- (BOOL)soundVolumeIsDefaultOutput {
    return self.mockPhysicalDefaultUID == nil && !self.mockNoSoundVolumeOutput;
}
- (SVCVolumeSupport)volumeSupportForOutputUID:(NSString *)uid {
    if (self.mockOutputUIDs != nil && (uid == nil || ![self.mockOutputUIDs containsObject:uid])) {
        return SVCVolumeSupportUnknown;
    }
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
    if (self.routeSucceeds && self.mockPhysicalDefaultUID == nil) {
        self.mockPhysicalDefaultUID = self.mockRestoredOutputUID;
    }
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
    [delegate consumeForwarderLine:@"Forwarding is active."];
    assert(delegate.startupRetryDelay == 0);
    assert(delegate.appState == SVCAppStateForwarding);
    [delegate forwarderStartupTimedOutForGeneration:delegate.launchGeneration];
    assert(delegate.scheduled.count == 0);

    // A transient exit code after readiness cannot restart a revoked session.
    [delegate consumeForwarderLine:@"Audio broker failed: connection revoked."];
    assert(delegate.appState == SVCAppStateError);
    [delegate forwarderDidTerminateWithStatus:EX_TEMPFAIL
                                      reason:NSTaskTerminationReasonExit
                                  generation:delegate.launchGeneration];
    assert(delegate.appState == SVCAppStateError && delegate.scheduled.count == 0);
}

static void TestRetryCancellation(void) {
    SVCRetryTestDelegate *delegate = StartRetryFixture();
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
    assert(task.terminations == 1);
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
    delegate.routeSucceeds = NO;
    [delegate forwarderStartupTimedOutForGeneration:delegate.launchGeneration];
    assert(delegate.appState == SVCAppStateError && delegate.scheduled.count == 0);
    assert([delegate.errorDetail isEqualToString:@"test restore failure"]);

    delegate = StartRetryFixture();
    delegate.mockRestoredOutputUID = @"fixed-output";
    [delegate consumeForwarderLine:@"Forwarder ready."];
    [delegate forwarderStartupTimedOutForGeneration:delegate.launchGeneration];
    assert(delegate.startupRetryPending && delegate.scheduled.count == 1);
    [delegate runNextScheduled];
    assert(delegate.launches == 2);
    [delegate consumeForwarderLine:@"Forwarder ready."];
    [delegate forwarderStartupTimedOutForGeneration:delegate.launchGeneration];
    assert([delegate.delays.lastObject isEqual:@2]);
    [delegate runNextScheduled];
    [delegate consumeForwarderLine:@"Forwarder ready."];
    [delegate consumeForwarderLine:@"Forwarding is active."];
    [delegate forwarderDidTerminateWithStatus:SIGKILL
                                      reason:NSTaskTerminationReasonUncaughtSignal
                                  generation:delegate.launchGeneration];
    assert(delegate.startupRetryPending && [delegate.delays.lastObject isEqual:@1]);
    [delegate defaultDevicesDidChange]; // Ignore the recovery's own route change.
    assert(delegate.scheduled.count == 1);
    [delegate runNextScheduled];
    assert(delegate.launches == 4);

    for (NSNumber *reason in @[@(NSTaskTerminationReasonExit), @(NSTaskTerminationReasonUncaughtSignal)]) {
        delegate = StartRetryFixture();
        NSUInteger generation = delegate.launchGeneration;
        [delegate forwarderDidTerminateWithStatus:reason.integerValue == NSTaskTerminationReasonExit ? 1 : EX_TEMPFAIL
                                          reason:reason.integerValue generation:generation];
        assert(delegate.appState == SVCAppStateError && delegate.scheduled.count == 0);
        assert(delegate.launchGeneration != generation);
    }
}

static SVCRetryTestDelegate *StartPhysicalFixture(BOOL ready) {
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
        assert(delegate.appState == SVCAppStateStarting);
        assert(delegate.launchGeneration != oldGeneration);
        assert(delegate.scheduled.count == 1 && delegate.launches == 1);
        assert([delegate.selectedPhysicalUID isEqualToString:@"second-output"]);
        assert([delegate.physicalOutputUID isEqualToString:@"second-output"]);
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
        assert(delegate.selections == 0);
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
        assert(!delegate.forwarderReady);
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

static void TestAutomaticOutputSelectionAndQuit(void) {
    SVCRetryTestDelegate *delegate = StartPhysicalFixture(YES);
    [delegate defaultDevicesDidChange]; // The virtual default is our own change.
    assert(delegate.launches == 1 && delegate.scheduled.count == 0);

    NSMenuItem *output = [NSMenuItem new];
    output.representedObject = @"selected-output";
    [delegate selectPhysicalOutput:output];
    assert([delegate.selectedPhysicalUID isEqualToString:@"selected-output"]);
    assert(!delegate.forwarderReady && delegate.scheduled.count == 1);
    [delegate runNextScheduled];
    assert(delegate.launches == 2);
    assert([delegate.launchedPhysicalUID isEqualToString:@"selected-output"]);

    [delegate applicationWillTerminate:[NSNotification
        notificationWithName:NSApplicationWillTerminateNotification object:nil]];
    delegate.mockPhysicalDefaultUID = @"second-output";
    [delegate defaultDevicesDidChange];
    assert(delegate.quitting && delegate.launches == 2);
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
    assert(menuDelegate.forwarderReady);
    assert(menuDelegate.appState == SVCAppStateForwarding);
    assert(menuDelegate.launchGeneration == menuGeneration);
    assert(menuDelegate.forwarderTask == activeTask && activeTask.running);
    assert(activeTask.terminations == 0 && menuDelegate.stops == 0);
    assert(menuDelegate.scheduled.count == 0 && menuDelegate.launches == 1);
    assert(menuDelegate.alerts == 0 && menuDelegate.restorations == 1);

    // An obsolete helper may fail before its ready acknowledgement. A new
    // physical destination still gets a fresh attempt.
    for (NSNumber *reason in @[@(NSTaskTerminationReasonExit),
                               @(NSTaskTerminationReasonUncaughtSignal)]) {
        SVCRetryTestDelegate *delegate = StartPhysicalFixture(NO);
        delegate.mockPhysicalDefaultUID = @"second-output";
        [delegate consumeForwarderLine:@"AudioDeviceStart failed: old device removed"];
        [delegate forwarderDidTerminateWithStatus:1 reason:reason.integerValue
                                      generation:delegate.launchGeneration];
        assert(delegate.selections == 0);
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
        assert(!delegate.forwarderReady);
        assert(delegate.appState == SVCAppStateError);
        assert(delegate.launchGeneration != generation);
        assert(delegate.selections == selections && delegate.stops == 1);
        assert(delegate.scheduled.count == 0 && delegate.lineBuffer.length == 0);
        assert([delegate.errorDetail isEqualToString:@"test restore failure"]);
        assert(delegate.alerts == 0);
        [delegate consumeForwarderLine:@"Forwarder ready."];
        assert(delegate.selections == selections);
        [delegate defaultDevicesDidChange];
        assert(delegate.scheduled.count == 0);
        delegate.routeSucceeds = YES;
        delegate.mockPhysicalDefaultUID = @"third-output";
        [delegate defaultDevicesDidChange];
        [delegate runNextScheduled];
        assert([delegate.launchedPhysicalUID isEqualToString:@"third-output"]);
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

static SVCRetryTestDelegate *LaunchWithOutputs(NSArray<NSString *> *uids,
                                               NSString *defaultUID) {
    SVCRetryTestDelegate *delegate = [SVCRetryTestDelegate new];
    delegate.mockVolumeSupport = NativePolicySupport();
    delegate.mockOutputUIDs = uids;
    delegate.mockPhysicalDefaultUID = defaultUID;
    delegate.mockNoSoundVolumeOutput = defaultUID == nil;
    [delegate captureOutputInventory];
    assert([delegate launchForwarder]);
    return delegate;
}

static void ChooseOutput(SVCTestDelegate *delegate, NSString *uid) {
    NSMenuItem *output = [NSMenuItem new];
    output.representedObject = uid;
    [delegate selectPhysicalOutput:output];
}

static void TestRememberedOutputPriority(void) {
    [testDefaults removeObjectForKey:@"recentPhysicalDeviceUIDs"];
    // A preference written by a previous app version wins over the HAL default.
    [testDefaults setObject:@"other-native-output" forKey:@"physicalDeviceUID"];
    NSArray *all = @[@"fixed-output", @"native-output", @"other-native-output"];
    NSArray *remaining = @[@"fixed-output", @"native-output"];
    SVCRetryTestDelegate *delegate = LaunchWithOutputs(all, @"fixed-output");
    assert([delegate.directPhysicalUID isEqualToString:@"other-native-output"]);
    ChooseOutput(delegate, @"native-output");
    ChooseOutput(delegate, @"other-native-output");

    // macOS can fall back to a third device on disconnect. Prefer the previous
    // choice among connected outputs and keep the unavailable one remembered.
    delegate.mockOutputUIDs = remaining;
    delegate.mockPhysicalDefaultUID = @"fixed-output";
    [delegate defaultDevicesDidChange];
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"native-output"]);
    assert([delegate.selectedPhysicalUID isEqualToString:@"other-native-output"]);
    NSUInteger generation = delegate.launchGeneration;
    [delegate defaultDevicesDidChange];
    assert(delegate.launchGeneration == generation);

    // Read persisted history in a fresh delegate while the last choice is away.
    delegate = LaunchWithOutputs(remaining, @"fixed-output");
    assert([delegate.directPhysicalUID isEqualToString:@"native-output"]);
    assert([delegate.selectedPhysicalUID isEqualToString:@"other-native-output"]);
    delegate.mockOutputUIDs = all;
    [delegate defaultDevicesDidChange];
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"other-native-output"]);

    ChooseOutput(delegate, @"");
    delegate = LaunchWithOutputs(all, @"fixed-output");
    assert(delegate.selectedPhysicalUID.length == 0);
    assert([delegate.launchedPhysicalUID isEqualToString:@"fixed-output"]);
}

static void TestNewlyConnectedOutputs(void) {
    [testDefaults removeObjectForKey:@"recentPhysicalDeviceUIDs"];
    [testDefaults setObject:@"" forKey:@"physicalDeviceUID"];
    SVCRetryTestDelegate *delegate = LaunchWithOutputs(@[@"native-output"], @"native-output");
    // A new fixed-volume output should acquire the helper, even when macOS
    // keeps the same native default and emits only a device-list notification.
    delegate.mockOutputUIDs = @[@"native-output", @"fixed-output"];
    [delegate defaultDevicesDidChange];
    assert([delegate.selectedPhysicalUID isEqualToString:@"fixed-output"]);
    assert(delegate.scheduled.count == 1);
    NSUInteger generation = delegate.launchGeneration;
    delegate.mockOutputUIDs = @[@"fixed-output", @"native-output"];
    [delegate defaultDevicesDidChange];
    assert(delegate.launchGeneration == generation && delegate.scheduled.count == 1);
    [delegate runNextScheduled];
    assert([delegate.launchedPhysicalUID isEqualToString:@"fixed-output"]);
    [delegate consumeForwarderLine:@"Forwarder ready."];
    [delegate consumeForwarderLine:@"Forwarding is active."];
    assert(delegate.forwarderReady && delegate.mockPhysicalDefaultUID == nil);

    // Sound Volume still owns the default when a native device is attached.
    // A failed list read must not cause existing outputs to appear newly added.
    delegate.mockOutputUIDs = nil;
    [delegate defaultDevicesDidChange];
    delegate.mockOutputUIDs = @[@"other-native-output", @"native-output", @"fixed-output"];
    delegate.mockRestoredOutputUID = @"fixed-output";
    [delegate defaultDevicesDidChange];
    assert([delegate.selectedPhysicalUID isEqualToString:@"other-native-output"]);
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"other-native-output"]);
    assert(delegate.appState == SVCAppStateNativeVolume && !delegate.forwarderReady);

    // A queued device notification after quitting cannot change the preference.
    [delegate applicationWillTerminate:[NSNotification
        notificationWithName:NSApplicationWillTerminateNotification object:nil]];
    delegate.mockOutputUIDs = @[@"last-minute-output", @"other-native-output"];
    [delegate defaultDevicesDidChange];
    assert([delegate.selectedPhysicalUID isEqualToString:@"other-native-output"]);
    assert(delegate.scheduled.count == 0);
}

static void TestReconnectAfterAllOutputsDisappear(void) {
    [testDefaults removeObjectForKey:@"recentPhysicalDeviceUIDs"];
    [testDefaults setObject:@"native-output" forKey:@"physicalDeviceUID"];
    SVCRetryTestDelegate *delegate = LaunchWithOutputs(@[@"native-output"], @"native-output");
    delegate.mockOutputUIDs = @[];
    delegate.mockPhysicalDefaultUID = nil;
    delegate.mockNoSoundVolumeOutput = YES;
    [delegate defaultDevicesDidChange];
    assert(delegate.appState == SVCAppStateNoEligibleOutput);
    assert([delegate.selectedPhysicalUID isEqualToString:@"native-output"]);
    delegate.mockOutputUIDs = @[@"other-native-output"];
    [delegate defaultDevicesDidChange];
    assert(delegate.appState == SVCAppStateNativeVolume);
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"other-native-output"]);
}

static void TestConnectionNotificationOrdering(void) {
    for (NSNumber *listFirst in @[@YES, @NO]) {
        [testDefaults removeObjectForKey:@"recentPhysicalDeviceUIDs"];
        [testDefaults setObject:@"native-output" forKey:@"physicalDeviceUID"];
        SVCRetryTestDelegate *delegate = LaunchWithOutputs(@[@"native-output"], @"native-output");
        NSArray *connected = @[@"native-output", @"fixed-output"];
        if (listFirst.boolValue) delegate.mockOutputUIDs = connected;
        else delegate.mockPhysicalDefaultUID = @"fixed-output";
        [delegate defaultDevicesDidChange];
        delegate.mockPhysicalDefaultUID = @"fixed-output";
        delegate.mockOutputUIDs = connected;
        [delegate defaultDevicesDidChange];
        [delegate defaultDevicesDidChange];
        while (delegate.scheduled.count > 0) [delegate runNextScheduled];
        assert(delegate.launches == 1);
        assert([delegate.launchedPhysicalUID isEqualToString:@"fixed-output"]);
        assert([delegate.selectedPhysicalUID isEqualToString:@"fixed-output"]);
    }
}

static void TestSimultaneousConnections(void) {
    NSArray *expected = @[@"fixed-output", @"remembered-output", @"first-output"];
    for (NSString *winner in expected) {
        [testDefaults setObject:@"native-output" forKey:@"physicalDeviceUID"];
        NSArray *history = [winner isEqualToString:@"first-output"] ? @[] : @[@"remembered-output"];
        [testDefaults setObject:history forKey:@"recentPhysicalDeviceUIDs"];
        SVCRetryTestDelegate *delegate = LaunchWithOutputs(@[@"native-output"], @"native-output");
        // The inventory arrives in menu order. The current HAL default and
        // earlier selections have priority over the first new item.
        delegate.mockOutputUIDs = @[@"first-output", @"fixed-output", @"native-output", @"remembered-output"];
        if ([winner isEqualToString:@"fixed-output"]) delegate.mockPhysicalDefaultUID = winner;
        [delegate defaultDevicesDidChange];
        assert([delegate.selectedPhysicalUID isEqualToString:winner]);
        assert(delegate.scheduled.count == 1);
        [delegate runNextScheduled];
        assert([delegate.launchedPhysicalUID isEqualToString:winner]);
    }
}

static void TestDisconnectNotificationOrdering(void) {
    for (NSNumber *listFirst in @[@YES, @NO]) {
        NSString *preferred = @"other-native-output";
        NSString *previousChoice = @"fixed-output";
        NSString *systemFallback = @"native-output";
        [testDefaults setObject:preferred forKey:@"physicalDeviceUID"];
        [testDefaults setObject:@[preferred, previousChoice] forKey:@"recentPhysicalDeviceUIDs"];
        SVCRetryTestDelegate *delegate = LaunchWithOutputs(@[preferred, previousChoice, systemFallback], preferred);
        NSArray *remaining = @[previousChoice, systemFallback];
        if (listFirst.boolValue) delegate.mockOutputUIDs = remaining;
        else delegate.mockPhysicalDefaultUID = systemFallback;
        [delegate audioHardwareDidChange];
        delegate.mockPhysicalDefaultUID = systemFallback;
        delegate.mockOutputUIDs = remaining;
        [delegate audioHardwareDidChange];
        while (delegate.scheduled.count > 0) [delegate runNextScheduled];
        assert([delegate.selectedPhysicalUID isEqualToString:preferred]);
        assert([delegate.launchedPhysicalUID isEqualToString:previousChoice]);
        assert(delegate.launches == 1);
    }
}

static void TestForwarderReportsDisconnectBeforeDeviceList(void) {
    NSString *preferred = @"fixed-output";
    NSString *previousChoice = @"other-native-output";
    NSString *systemFallback = @"native-output";
    for (NSNumber *exitFirst in @[@YES, @NO]) {
        [testDefaults setObject:preferred forKey:@"physicalDeviceUID"];
        [testDefaults setObject:@[preferred, previousChoice] forKey:@"recentPhysicalDeviceUIDs"];
        SVCRetryTestDelegate *delegate = LaunchWithOutputs(@[preferred, previousChoice, systemFallback], preferred);
        [delegate consumeForwarderLine:@"Forwarder ready."];
        [delegate consumeForwarderLine:@"Forwarding is active."];
        assert(delegate.appState == SVCAppStateForwarding && delegate.launches == 1);

        delegate.mockPhysicalDefaultUID = systemFallback;
        NSUInteger generation = delegate.launchGeneration;
        if (exitFirst.boolValue) {
            [delegate forwarderDidTerminateWithStatus:0 reason:NSTaskTerminationReasonExit generation:generation];
        } else {
            [delegate consumeForwarderLine:@"Sound Volume is no longer selected; stopping physical IO."];
        }
        assert([delegate.selectedPhysicalUID isEqualToString:preferred]);
        delegate.mockOutputUIDs = @[previousChoice, systemFallback];
        while (delegate.scheduled.count > 0) [delegate runNextScheduled];
        assert([delegate.selectedPhysicalUID isEqualToString:preferred]);
        assert([delegate.currentPhysicalDefaultUID isEqualToString:previousChoice]);
        assert(delegate.appState == SVCAppStateNativeVolume && delegate.directSelections == 1);
        assert(!delegate.forwarderReady && delegate.launches == 1);
    }
}

static void TestDelayedOutputCapability(void) {
    [testDefaults setObject:@"native-output" forKey:@"physicalDeviceUID"];
    SVCRetryTestDelegate *delegate = LaunchWithOutputs(@[@"native-output"], @"native-output");
    delegate.mockOutputUIDs = @[@"native-output", @"unknown-output"];
    [delegate audioHardwareDidChange];
    [delegate runNextScheduled];
    assert(delegate.appState == SVCAppStateNoEligibleOutput);
    assert([delegate.selectedPhysicalUID isEqualToString:@"unknown-output"]);
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"native-output"]);
    // No further HAL event occurs when the new device's controls become readable.
    delegate.mockVolumeSupport = @{@"unknown-output": @(SVCVolumeSupportNative)};
    while (delegate.scheduled.count > 0) [delegate runNextScheduled];
    assert(delegate.appState == SVCAppStateNativeVolume && delegate.launches == 0);
    assert([delegate.directPhysicalUID isEqualToString:@"unknown-output"]);
}

static void TestNativeLaunchAndSelection(void) {
    [testDefaults setBool:NO forKey:@"forwardingEnabled"];
    [testDefaults setObject:@"" forKey:@"physicalDeviceUID"];
    // Exercise the production launch preflight. A native output must return
    // before looking for or launching the bundled helper.
    SVCTestDelegate *delegate = [SVCTestDelegate new];
    delegate.routeSucceeds = YES;
    delegate.mockVolumeSupport = NativePolicySupport();
    delegate.mockPhysicalDefaultUID = @"native-output";
    assert([delegate launchForwarder]);
    assert(delegate.appState == SVCAppStateNativeVolume);
    assert(delegate.forwarderTask == nil && delegate.selections == 0);
    assert(delegate.directSelections == 0 && delegate.alerts == 0);
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"native-output"]);

    NSMenuItem *output = [NSMenuItem new];
    output.representedObject = @"other-native-output";
    [delegate selectPhysicalOutput:output];
    assert(delegate.appState == SVCAppStateNativeVolume);
    assert(delegate.directSelections == 1 && delegate.selections == 0);
    assert([delegate.directPhysicalUID isEqualToString:@"other-native-output"]);
    assert([delegate.currentPhysicalDefaultUID isEqualToString:@"other-native-output"]);
    NSUInteger generation = delegate.launchGeneration;
    [delegate defaultDevicesDidChange];
    assert(delegate.launchGeneration == generation && delegate.directSelections == 1);


}

static void TestNativeAndFixedTransitions(void) {
    // Returning to native control cancels a pending launch, an established
    // helper, or its delayed startup retry.
    for (NSUInteger stage = 0; stage < 3; ++stage) {
        [testDefaults setObject:@"" forKey:@"physicalDeviceUID"];
        SVCRetryTestDelegate *delegate = [SVCRetryTestDelegate new];
        delegate.mockVolumeSupport = NativePolicySupport();
        delegate.mockPhysicalDefaultUID = @"native-output";
        assert([delegate launchForwarder]);
        assert(delegate.launches == 0 && delegate.appState == SVCAppStateNativeVolume);

        delegate.mockPhysicalDefaultUID = @"fixed-output";
        [delegate defaultDevicesDidChange];
        assert(delegate.scheduled.count == 1);
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
        assert(!delegate.forwarderReady);
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
        assert(delegate.launches == (stage == 0 ? 0 : 1));

        delegate.mockPhysicalDefaultUID = @"fixed-output";
        [delegate defaultDevicesDidChange];
        assert(delegate.appState == SVCAppStateStarting);
        assert(delegate.scheduled.count == 1);
    }
}

static void TestUnknownVolumeSupport(void) {
    [testDefaults setObject:@"" forKey:@"physicalDeviceUID"];
    SVCTestDelegate *missing = [SVCTestDelegate new];
    missing.routeSucceeds = YES;
    missing.mockNoSoundVolumeOutput = YES;
    missing.mockVolumeSupport = @{@"": @(SVCVolumeSupportUnknown)};
    assert([missing launchForwarder]);
    assert(missing.appState == SVCAppStateNoEligibleOutput);
    assert(missing.forwarderTask == nil && missing.selections == 0);

    SVCRetryTestDelegate *delegate = [SVCRetryTestDelegate new];
    delegate.mockVolumeSupport = NativePolicySupport();
    delegate.mockPhysicalDefaultUID = @"unknown-output";
    assert([delegate launchForwarder]);
    assert(delegate.appState == SVCAppStateNoEligibleOutput);
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
        assert(!delegate.forwarderReady);
        assert(delegate.selections == 0 && delegate.scheduled.count == 0);
        assert(delegate.lineBuffer.length == 0);
        assert(delegate.appState == (support.integerValue == SVCVolumeSupportNative
            ? SVCAppStateNativeVolume : SVCAppStateNoEligibleOutput));
    }
}

static void TestRoutingStatusFollowsAppState(void) {
    SVCTestDelegate *delegate = [SVCTestDelegate new];
    delegate.menu = [[NSMenu alloc] initWithTitle:@"SoundVolumeControl"];
    [delegate buildMenu];
    NSMenuItem *status = [delegate.menu itemAtIndex:0];
    assert(!status.enabled && status.action == NULL);

    delegate.appState = SVCAppStateNativeVolume;
    assert([status.title isEqualToString:@"Using macOS volume control"]);
    delegate.appState = SVCAppStateStarting;
    assert([status.title isEqualToString:@"Preparing Sound Volume"]);
    delegate.startupRetryPending = YES;
    delegate.appState = SVCAppStateStarting;
    assert([status.title isEqualToString:@"Retrying audio helper"]);
    delegate.appState = SVCAppStateForwarding;
    assert([status.title isEqualToString:@"Routing through Sound Volume"]);
    delegate.errorDetail = @"Audio helper stopped (status 1).";
    delegate.appState = SVCAppStateError;
    assert([status.title isEqualToString:@"Error — Audio helper stopped (status 1)."]);
    delegate.appState = SVCAppStateNoEligibleOutput;
    assert([status.title isEqualToString:@"Waiting for a compatible output"]);
}

@interface SVCStatusTestUpdateChecker : SVCUpdateChecker
@property(nonatomic, copy) NSString *mockAvailableVersion;
@end
@implementation SVCStatusTestUpdateChecker
- (NSString *)availableVersion { return self.mockAvailableVersion; }
@end

@interface SVCStatusTestButton : NSObject
@property(nonatomic, copy) NSAttributedString *attributedTitle;
@property(nonatomic, copy) NSString *toolTip;
@property(nonatomic, copy) NSString *accessibilityLabel;
@end
@implementation SVCStatusTestButton
@end

@interface SVCStatusTestItem : NSObject
@property(nonatomic, strong) SVCStatusTestButton *button;
@end
@implementation SVCStatusTestItem
@end

static void TestUpdateStatusPriority(void) {
    SVCTestDelegate *delegate = [SVCTestDelegate new];
    SVCStatusTestUpdateChecker *checker = [[SVCStatusTestUpdateChecker alloc]
        initWithVersion:@"0.8.8" defaults:testDefaults];
    delegate.updateChecker = checker;
    SVCStatusTestItem *statusItem = [SVCStatusTestItem new];
    SVCStatusTestButton *button = [SVCStatusTestButton new];
    statusItem.button = button;
    delegate.statusItem = (id)statusItem;
    delegate.menu = [[NSMenu alloc] initWithTitle:@"SoundVolumeControl"];
    [delegate buildMenu];
    delegate.appState = SVCAppStateForwarding;
    assert(delegate.availableUpdateMenuItem.hidden);
    assert([NSColor.systemGreenColor isEqual:[button.attributedTitle
        attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]]);

    checker.mockAvailableVersion = @"0.8.9";
    [delegate refreshUpdateMenu];
    assert(!delegate.availableUpdateMenuItem.hidden);
    assert([delegate.availableUpdateMenuItem.title isEqualToString:@"Update available — 0.8.9…"]);
    assert([NSColor.systemYellowColor isEqual:[button.attributedTitle
        attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]]);

    delegate.errorDetail = @"Audio helper stopped.";
    delegate.appState = SVCAppStateError;
    assert([NSColor.systemRedColor isEqual:[button.attributedTitle
        attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]]);
    assert([delegate.statusMenuItem.title containsString:@"Audio helper stopped."]);
    assert(!delegate.availableUpdateMenuItem.hidden);
    assert([button.accessibilityLabel containsString:@"Update available"]);

    delegate.appState = SVCAppStateNativeVolume;
    assert([NSColor.systemYellowColor isEqual:[button.attributedTitle
        attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]]);
    checker.mockAvailableVersion = nil;
    [delegate refreshUpdateMenu];
    assert(delegate.availableUpdateMenuItem.hidden);
    assert([NSColor.systemGrayColor isEqual:[button.attributedTitle
        attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]]);
}

int main(void) {
    @autoreleasepool {
        NSString *suite = [NSString stringWithFormat:
            @"org.soundvolumecontrol.tests.%d", getpid()];
        testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Method method = class_getClassMethod(NSUserDefaults.class,
                                              @selector(standardUserDefaults));
        IMP original = method_setImplementation(method, (IMP)TestStandardDefaults);
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

        // A fresh launch can fail to select the virtual output.
        delegate.forwarderReady = NO;
        delegate.appState = SVCAppStateStarting;
        delegate.routeSucceeds = NO;
        [delegate consumeForwarderData:[@"Forwarder ready.\nForwarding is active.\n"
            dataUsingEncoding:NSUTF8StringEncoding]];
        assert(delegate.appState == SVCAppStateError);
        assert(delegate.restorations == 1 && delegate.stops == 1);
        assert(delegate.lineBuffer.length == 0);
        [delegate consumeForwarderLine:@"Forwarder ready."];
        assert(delegate.selections == 2); // An obsolete acknowledgement cannot select the route.

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
        TestAutomaticOutputSelectionAndQuit();
        TestSourceChangeFailureBoundaries();
        TestNativeLaunchAndSelection();
        TestNativeAndFixedTransitions();
        TestUnknownVolumeSupport();
        TestCapabilityChangeBeforeReadiness();
        TestRememberedOutputPriority();
        TestNewlyConnectedOutputs();
        TestReconnectAfterAllOutputsDisappear();
        TestConnectionNotificationOrdering();
        TestSimultaneousConnections();
        TestDisconnectNotificationOrdering();
        TestForwarderReportsDisconnectBeforeDeviceList();
        TestDelayedOutputCapability();
        TestRoutingStatusFollowsAppState();
        TestUpdateStatusPriority();

        [testDefaults removePersistentDomainForName:suite];
        method_setImplementation(method, original);
        puts("app-lifecycle-tests: PASS (native volume policy, late startup recovery, source switching, output selection history, device hotplug, bounded backoff, cancellation, safe routing, ready handshake, stale output, safe Quit)");
    }
    return 0;
}
