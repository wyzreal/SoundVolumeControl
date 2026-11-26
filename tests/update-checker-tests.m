#import "../app/UpdateChecker.h"

#include <assert.h>
#include <stdio.h>
#include <unistd.h>

@interface SVCUpdateChecker (Testing)
@property(nonatomic, readonly) NSTimer *automaticCheckTimer;
- (id<SVCUpdateRequest>)makeRequestWithAPICooldown:(NSTimeInterval)cooldown
                                         completion:(SVCUpdateCheckCompletion)completion;
@end

@interface SVCUpdateTestTask : NSObject <SVCUpdateRequest>
@property(nonatomic, copy) SVCUpdateCheckCompletion completion;
@property(nonatomic) BOOL resumed;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) NSTimeInterval cooldown;
@end

@implementation SVCUpdateTestTask
- (void)resume { self.resumed = YES; }
- (void)cancel { self.cancelled = YES; }
@end

@interface SVCUpdateTestChecker : SVCUpdateChecker
@property(nonatomic, strong) NSMutableArray<SVCUpdateTestTask *> *requests;
@end

@implementation SVCUpdateTestChecker
- (id<SVCUpdateRequest>)makeRequestWithAPICooldown:(NSTimeInterval)cooldown
                                         completion:(SVCUpdateCheckCompletion)completion {
    if (self.requests == nil) self.requests = [NSMutableArray array];
    SVCUpdateTestTask *task = [[SVCUpdateTestTask alloc] init];
    task.cooldown = cooldown;
    task.completion = completion;
    [self.requests addObject:task];
    return task;
}
@end

static void Complete(SVCUpdateTestTask *task, SVCUpdateCheckResult result,
                     NSString *version, NSTimeInterval retryAfter) {
    assert(task.resumed);
    task.completion(result, version, nil, retryAfter);

    __block BOOL delivered = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        delivered = YES;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!delivered && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
    assert(delivered);
}

static void TestManualJoinsAutomatic(NSUserDefaults *defaults) {
    SVCUpdateTestChecker *checker = [[SVCUpdateTestChecker alloc]
        initWithVersion:@"0.8.8" defaults:defaults];
    assert(checker.automaticChecks && !checker.checking);
    __block NSUInteger manualResults = 0;
    checker.manualCheckFinished = ^(SVCUpdateCheckResult result, NSString *version,
                                      NSString *detail) {
        (void)detail;
        assert(result == SVCUpdateCheckAvailable && [version isEqualToString:@"0.8.9"]);
        ++manualResults;
    };

    [checker start];
    assert(checker.checking && checker.requests.count == 1);
    [checker checkManually];
    [checker checkManually];
    assert(checker.requests.count == 1);
    Complete(checker.requests.lastObject, SVCUpdateCheckAvailable, @"0.8.9", 0);
    assert(manualResults == 1 && !checker.checking);
    assert([checker.availableVersion isEqualToString:@"0.8.9"]);
    NSTimeInterval delay = checker.automaticCheckTimer.fireDate.timeIntervalSinceNow;
    assert(delay > 23 * 60 * 60 && delay <= 24 * 60 * 60);
    [checker stop];
}

static void TestCacheAndRetries(NSUserDefaults *defaults) {
    SVCUpdateTestChecker *checker = [[SVCUpdateTestChecker alloc]
        initWithVersion:@"0.8.8" defaults:defaults];
    assert([checker.availableVersion isEqualToString:@"0.8.9"]);
    [checker start];
    assert(!checker.checking && checker.automaticCheckTimer != nil);
    [checker setAutomaticChecksEnabled:NO];
    assert(!checker.automaticChecks && checker.automaticCheckTimer == nil);
    assert([checker.availableVersion isEqualToString:@"0.8.9"]);

    [checker checkManually];
    Complete(checker.requests.lastObject, SVCUpdateCheckFailed, nil, 1800);
    assert([checker.availableVersion isEqualToString:@"0.8.9"]);
    assert(checker.automaticCheckTimer == nil);
    [checker stop];

    checker = [[SVCUpdateTestChecker alloc] initWithVersion:@"0.8.8" defaults:defaults];
    [checker start];
    assert(!checker.automaticChecks && checker.automaticCheckTimer == nil);
    [checker setAutomaticChecksEnabled:YES];
    NSTimeInterval delay = checker.automaticCheckTimer.fireDate.timeIntervalSinceNow;
    assert(delay > 1700 && delay <= 1800);

    [checker checkManually];
    assert(checker.requests.lastObject.cooldown > 1700);
    NSDate *deadline = [defaults objectForKey:@"releaseAPIRetryDate"];
    Complete(checker.requests.lastObject, SVCUpdateCheckFailed, nil, 1800);
    assert([deadline isEqual:[defaults objectForKey:@"releaseAPIRetryDate"]]);
    assert([checker.availableVersion isEqualToString:@"0.8.9"]);
    [defaults setObject:NSDate.distantPast forKey:@"releaseAPIRetryDate"];
    [checker checkManually];
    assert(checker.requests.lastObject.cooldown == 0);
    Complete(checker.requests.lastObject, SVCUpdateCheckMissingInstaller, @"0.9.0", 0);
    assert(checker.availableVersion == nil);
    [checker stop];
}

static void TestPublicLatestDuringCooldown(NSUserDefaults *defaults) {
    [defaults setObject:@"0.9.3" forKey:@"availableUpdateVersion"];
    SVCUpdateTestChecker *checker = [[SVCUpdateTestChecker alloc]
        initWithVersion:@"0.9.1" defaults:defaults];
    [checker start];
    assert(checker.requests.lastObject.cooldown == 0);
    Complete(checker.requests.lastObject, SVCUpdateCheckLatestOnly, @"0.9.2", 120);
    assert([checker.availableVersion isEqualToString:@"0.9.3"]);
    NSDate *deadline = [defaults objectForKey:@"releaseAPIRetryDate"];
    assert(deadline.timeIntervalSinceNow > 110 && deadline.timeIntervalSinceNow <= 120);
    assert(fabs([checker.automaticCheckTimer.fireDate timeIntervalSinceDate:deadline]) < 1);
    [checker stop];

    // Both the timer and the manual entry point respect the server deadline
    // after a relaunch, even if an automatic check becomes due early.
    [defaults setObject:NSDate.distantPast forKey:@"nextAutomaticUpdateCheck"];
    checker = [[SVCUpdateTestChecker alloc] initWithVersion:@"0.9.1" defaults:defaults];
    [checker start];
    assert(checker.requests.lastObject.cooldown > 110);
    __block NSString *manualVersion = nil;
    checker.manualCheckFinished = ^(SVCUpdateCheckResult result, NSString *version, NSString *detail) {
        (void)detail;
        assert(result == SVCUpdateCheckLatestOnly);
        manualVersion = version;
    };
    [checker checkManually];
    assert(checker.requests.count == 1);
    Complete(checker.requests.lastObject, SVCUpdateCheckLatestOnly, @"0.9.1", 120);
    assert([manualVersion isEqualToString:@"0.9.1"]);
    assert([checker.availableVersion isEqualToString:@"0.9.3"]);
    [checker checkManually];
    assert(checker.requests.lastObject.cooldown > 110);
    Complete(checker.requests.lastObject, SVCUpdateCheckLatestOnly, @"0.9.4", 120);
    assert([manualVersion isEqualToString:@"0.9.4"]);
    assert([checker.availableVersion isEqualToString:@"0.9.4"]);
    assert([[defaults stringForKey:@"availableUpdateVersion"] isEqualToString:@"0.9.4"]);
    assert([deadline isEqual:[defaults objectForKey:@"releaseAPIRetryDate"]]);
    [checker stop];
}

static void TestCancellation(NSUserDefaults *defaults) {
    SVCUpdateTestChecker *checker = [[SVCUpdateTestChecker alloc]
        initWithVersion:@"0.8.8" defaults:defaults];
    [checker start];
    SVCUpdateTestTask *automaticTask = checker.requests.lastObject;
    [checker setAutomaticChecksEnabled:NO];
    assert(automaticTask.cancelled && !checker.checking);

    [checker checkManually];
    SVCUpdateTestTask *manualTask = checker.requests.lastObject;
    assert(manualTask != automaticTask);
    Complete(automaticTask, SVCUpdateCheckAvailable, @"0.8.9", 0);
    assert(checker.availableVersion == nil && checker.checking);

    [checker setAutomaticChecksEnabled:YES];
    [checker setAutomaticChecksEnabled:NO];
    assert(!manualTask.cancelled && checker.checking);
    Complete(manualTask, SVCUpdateCheckAvailable, @"0.8.9", 0);
    assert([checker.availableVersion isEqualToString:@"0.8.9"]);

    [checker checkManually];
    SVCUpdateTestTask *lastTask = checker.requests.lastObject;
    [checker stop];
    assert(lastTask.cancelled && !checker.checking);
    Complete(lastTask, SVCUpdateCheckCurrent, @"0.8.8", 0);
    assert([checker.availableVersion isEqualToString:@"0.8.9"]);

    SVCUpdateChecker *updated = [[SVCUpdateChecker alloc]
        initWithVersion:@"0.8.9" defaults:defaults];
    assert(updated.availableVersion == nil);
}

static void TestClockRollback(NSUserDefaults *defaults) {
    [defaults setObject:[NSDate dateWithTimeIntervalSinceNow:72 * 60 * 60]
                 forKey:@"nextAutomaticUpdateCheck"];
    SVCUpdateTestChecker *checker = [[SVCUpdateTestChecker alloc]
        initWithVersion:@"0.8.8" defaults:defaults];
    [checker start];
    NSTimeInterval delay = checker.automaticCheckTimer.fireDate.timeIntervalSinceNow;
    assert(delay > 23 * 60 * 60 && delay <= 24 * 60 * 60);
    [checker stop];
}

int main(void) {
    @autoreleasepool {
        NSString *suite = [NSString stringWithFormat:@"org.soundvolumecontrol.update-tests.%d",
                           getpid()];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults removePersistentDomainForName:suite];
        TestManualJoinsAutomatic(defaults);
        TestCacheAndRetries(defaults);
        [defaults removePersistentDomainForName:suite];
        TestPublicLatestDuringCooldown(defaults);
        [defaults removePersistentDomainForName:suite];
        TestCancellation(defaults);
        [defaults removePersistentDomainForName:suite];
        TestClockRollback(defaults);
        [defaults removePersistentDomainForName:suite];
        puts("update-checker-tests: PASS");
    }
    return 0;
}
