#import "../app/UpdateChecker.h"

#include <assert.h>
#include <stdio.h>
#include <unistd.h>

@interface SVCUpdateChecker (Testing)
@property(nonatomic, readonly) NSTimer *automaticCheckTimer;
- (NSURLSessionDataTask *)makeTaskWithCompletion:(SVCUpdateCheckCompletion)completion;
@end

@interface SVCUpdateTestTask : NSObject
@property(nonatomic, copy) SVCUpdateCheckCompletion completion;
@property(nonatomic) BOOL resumed;
@property(nonatomic) BOOL cancelled;
@end

@implementation SVCUpdateTestTask
- (void)resume { self.resumed = YES; }
- (void)cancel { self.cancelled = YES; }
@end

@interface SVCUpdateTestChecker : SVCUpdateChecker
@property(nonatomic, strong) NSMutableArray<SVCUpdateTestTask *> *requests;
@end

@implementation SVCUpdateTestChecker
- (NSURLSessionDataTask *)makeTaskWithCompletion:(SVCUpdateCheckCompletion)completion {
    if (self.requests == nil) self.requests = [NSMutableArray array];
    SVCUpdateTestTask *task = [[SVCUpdateTestTask alloc] init];
    task.completion = completion;
    [self.requests addObject:task];
    return (NSURLSessionDataTask *)task;
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
    Complete(checker.requests.lastObject, SVCUpdateCheckMissingInstaller, @"0.9.0", 0);
    assert(checker.availableVersion == nil);
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
        TestCancellation(defaults);
        [defaults removePersistentDomainForName:suite];
        TestClockRollback(defaults);
        [defaults removePersistentDomainForName:suite];
        puts("update-checker-tests: PASS");
    }
    return 0;
}
