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

        [testDefaults removePersistentDomainForName:suite];
        method_setImplementation(method, original);
        puts("app-lifecycle-tests: PASS (ready handshake, startup failure, stale output, safe Quit)");
    }
    return 0;
}
