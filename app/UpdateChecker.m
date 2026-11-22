#import "UpdateChecker.h"

#include <math.h>

static NSString *const SVCAutomaticUpdatesKey = @"checkForUpdatesAutomatically";
static NSString *const SVCAvailableUpdateKey = @"availableUpdateVersion";
static NSString *const SVCNextUpdateCheckKey = @"nextAutomaticUpdateCheck";
static const NSTimeInterval SVCUpdateCheckInterval = 24 * 60 * 60;
static const NSTimeInterval SVCInitialUpdateRetry = 15 * 60;
static const NSTimeInterval SVCMaximumUpdateRetry = 60 * 60;

@interface SVCUpdateChecker ()
@property(nonatomic, copy) NSString *installedVersion;
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, copy, readwrite) NSString *availableVersion;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSTimer *automaticCheckTimer;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL manualResultRequested;
@property(nonatomic) NSUInteger requestGeneration;
@property(nonatomic) NSTimeInterval retryDelay;
@end

@implementation SVCUpdateChecker

- (instancetype)initWithVersion:(NSString *)version defaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (self != nil) {
        _installedVersion = [version copy];
        _defaults = defaults;
        NSString *savedVersion = [defaults stringForKey:SVCAvailableUpdateKey];
        if (savedVersion != nil && SVCUpdateVersionIsNewer(savedVersion, version)) {
            _availableVersion = [savedVersion copy];
        } else if (savedVersion != nil) {
            [defaults removeObjectForKey:SVCAvailableUpdateKey];
        }
    }
    return self;
}

- (BOOL)automaticChecks {
    return [self.defaults objectForKey:SVCAutomaticUpdatesKey] == nil
        || [self.defaults boolForKey:SVCAutomaticUpdatesKey];
}

- (BOOL)isChecking {
    return self.task != nil;
}

- (void)start {
    if (self.running) return;
    self.running = YES;
    [self scheduleAutomaticCheck];
}

- (void)stop {
    self.running = NO;
    [self.automaticCheckTimer invalidate];
    self.automaticCheckTimer = nil;
    [self cancelRequest];
}

- (void)checkManually {
    if (!self.running) return;
    self.manualResultRequested = YES;
    [self beginCheck];
}

- (void)setAutomaticChecksEnabled:(BOOL)enabled {
    if (enabled == self.automaticChecks) return;
    [self.defaults setBool:enabled forKey:SVCAutomaticUpdatesKey];
    if (!enabled && !self.manualResultRequested) {
        [self cancelRequest];
    }
    [self notifyStateChanged];
    [self scheduleAutomaticCheck];
}

- (void)scheduleAutomaticCheck {
    [self.automaticCheckTimer invalidate];
    self.automaticCheckTimer = nil;
    if (!self.running || !self.automaticChecks || self.checking) return;

    id nextCheck = [self.defaults objectForKey:SVCNextUpdateCheckKey];
    NSTimeInterval delay = [nextCheck isKindOfClass:NSDate.class]
        ? [nextCheck timeIntervalSinceNow] : 0;
    if (delay <= 0) {
        [self beginCheck];
        return;
    }

    // A persisted deadline can move into the distant future after a clock rollback.
    delay = MIN(delay, SVCUpdateCheckInterval);
    __weak SVCUpdateChecker *weakSelf = self;
    self.automaticCheckTimer = [NSTimer timerWithTimeInterval:delay repeats:NO
        block:^(NSTimer *timer) {
            SVCUpdateChecker *checker = weakSelf;
            if (timer != checker.automaticCheckTimer) return;
            [checker beginCheck];
        }];
    [[NSRunLoop mainRunLoop] addTimer:self.automaticCheckTimer forMode:NSRunLoopCommonModes];
}

- (NSURLSessionDataTask *)makeTaskWithCompletion:(SVCUpdateCheckCompletion)completion {
    return SVCCheckLatestRelease(self.installedVersion, completion);
}

- (void)beginCheck {
    if (self.checking) return;
    [self.automaticCheckTimer invalidate];
    self.automaticCheckTimer = nil;

    NSUInteger generation = ++self.requestGeneration;
    __weak SVCUpdateChecker *weakSelf = self;
    self.task = [self makeTaskWithCompletion:^(
        SVCUpdateCheckResult result, NSString *version, NSString *detail, NSTimeInterval retryAfter
    ) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SVCUpdateChecker *checker = weakSelf;
            if (generation != checker.requestGeneration || !checker.checking) return;
            [checker finishCheck:result version:version detail:detail retryAfter:retryAfter];
        });
    }];
    [self.task resume];
    [self notifyStateChanged];
}

- (void)cancelRequest {
    ++self.requestGeneration;
    [self.task cancel];
    self.task = nil;
    self.manualResultRequested = NO;
}

- (void)finishCheck:(SVCUpdateCheckResult)result version:(NSString *)version
             detail:(NSString *)detail retryAfter:(NSTimeInterval)retryAfter {
    BOOL notifyManual = self.manualResultRequested;
    self.manualResultRequested = NO;
    self.task = nil;

    NSTimeInterval nextCheckDelay = SVCUpdateCheckInterval;
    if (result == SVCUpdateCheckFailed) {
        self.retryDelay = self.retryDelay == 0
            ? SVCInitialUpdateRetry : MIN(self.retryDelay * 2, SVCMaximumUpdateRetry);
        nextCheckDelay = isfinite(retryAfter)
            ? MAX(self.retryDelay, MIN(retryAfter, SVCUpdateCheckInterval)) : self.retryDelay;
    } else {
        self.retryDelay = 0;
        if (result == SVCUpdateCheckAvailable) {
            self.availableVersion = version;
            [self.defaults setObject:version forKey:SVCAvailableUpdateKey];
        } else {
            self.availableVersion = nil;
            [self.defaults removeObjectForKey:SVCAvailableUpdateKey];
        }
    }
    [self.defaults setObject:[NSDate dateWithTimeIntervalSinceNow:nextCheckDelay]
                      forKey:SVCNextUpdateCheckKey];
    [self scheduleAutomaticCheck];
    [self notifyStateChanged];

    if (notifyManual && self.manualCheckFinished != nil) {
        self.manualCheckFinished(result, version, detail);
    }
}

- (void)notifyStateChanged {
    if (self.stateChanged != nil) self.stateChanged();
}

@end
