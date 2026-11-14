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
@end

@implementation SVCTestDelegate
- (void)updatePresentation {}
- (void)capturePhysicalDefaults {}
- (void)removeDefaultDeviceListeners {}
- (void)rebuildPhysicalOutputMenu {}
- (BOOL)selectSoundVolumeWithDetail:(NSString **)detail {
    ++self.selections;
    if (detail != NULL) *detail = @"test route failure";
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
    ++self.launches;
    ++self.launchGeneration;
    self.forwarderReady = NO;
    self.startupRetryPending = NO;
    self.errorDetail = nil;
    self.appState = SVCAppStateStarting;
    self.launchedPhysicalUID = [self selectedPhysicalUID];
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
    SVCRetryTestDelegate *delegate = [SVCRetryTestDelegate new];
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

        [testDefaults removePersistentDomainForName:suite];
        method_setImplementation(method, original);
        puts("app-lifecycle-tests: PASS (late startup recovery, bounded backoff, cancellation, safe routing, ready handshake, stale output, safe Quit)");
    }
    return 0;
}
