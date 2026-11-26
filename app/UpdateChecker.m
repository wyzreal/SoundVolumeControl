#import "UpdateChecker.h"

#include <math.h>

static NSString *const SVCAutomaticUpdatesKey = @"checkForUpdatesAutomatically";
static NSString *const SVCAvailableUpdateKey = @"availableUpdateVersion";
static NSString *const SVCNextUpdateCheckKey = @"nextAutomaticUpdateCheck";
static NSString *const SVCReleaseAPIRetryDateKey = @"releaseAPIRetryDate";
static const NSTimeInterval SVCUpdateCheckInterval = 24 * 60 * 60;
static const NSTimeInterval SVCInitialUpdateRetry = 15 * 60;
static const NSTimeInterval SVCMaximumUpdateRetry = 60 * 60;

@interface SVCUpdateChecker ()
@property(nonatomic, copy) NSString *installedVersion;
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, copy, readwrite) NSString *availableVersion;
@property(nonatomic, strong) id<SVCUpdateRequest> request;
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
    return self.request != nil;
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

- (NSTimeInterval)remainingAPICooldown {
    id deadline = [self.defaults objectForKey:SVCReleaseAPIRetryDateKey];
    return [deadline isKindOfClass:NSDate.class] ? MAX(0, [deadline timeIntervalSinceNow]) : 0;
}

- (id<SVCUpdateRequest>)makeRequestWithAPICooldown:(NSTimeInterval)cooldown
                                        completion:(SVCUpdateCheckCompletion)completion {
    if (cooldown > 0) {
        return SVCCheckPublicLatestRelease(self.installedVersion, cooldown, completion);
    }
    return SVCCheckLatestRelease(self.installedVersion, completion);
}

- (void)beginCheck {
    if (self.checking) return;
    [self.automaticCheckTimer invalidate];
    self.automaticCheckTimer = nil;

    NSUInteger generation = ++self.requestGeneration;
    NSTimeInterval cooldown = [self remainingAPICooldown];
    __weak SVCUpdateChecker *weakSelf = self;
    self.request = [self makeRequestWithAPICooldown:cooldown completion:^(
        SVCUpdateCheckResult result, NSString *version, NSString *detail, NSTimeInterval retryAfter
    ) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SVCUpdateChecker *checker = weakSelf;
            if (generation != checker.requestGeneration || !checker.checking) return;
            [checker finishCheck:result version:version detail:detail retryAfter:retryAfter
                      publicOnly:cooldown > 0];
        });
    }];
    [self.request resume];
    [self notifyStateChanged];
}

- (void)cancelRequest {
    ++self.requestGeneration;
    [self.request cancel];
    self.request = nil;
    self.manualResultRequested = NO;
}

- (void)finishCheck:(SVCUpdateCheckResult)result version:(NSString *)version
             detail:(NSString *)detail retryAfter:(NSTimeInterval)retryAfter
         publicOnly:(BOOL)publicOnly {
    BOOL notifyManual = self.manualResultRequested;
    self.manualResultRequested = NO;
    self.request = nil;

    // Only a fresh API response can set its retry deadline. Rechecking the
    // public release during the cooldown must not push the deadline forward.
    if (!publicOnly) {
        if ((result == SVCUpdateCheckFailed || result == SVCUpdateCheckLatestOnly)
            && isfinite(retryAfter) && retryAfter > 0) {
            [self.defaults setObject:[NSDate dateWithTimeIntervalSinceNow:retryAfter]
                              forKey:SVCReleaseAPIRetryDateKey];
        } else {
            [self.defaults removeObjectForKey:SVCReleaseAPIRetryDateKey];
        }
    }

    NSTimeInterval nextCheckDelay = SVCUpdateCheckInterval;
    if (result == SVCUpdateCheckFailed) {
        self.retryDelay = self.retryDelay == 0
            ? SVCInitialUpdateRetry : MIN(self.retryDelay * 2, SVCMaximumUpdateRetry);
        nextCheckDelay = MAX(self.retryDelay, [self remainingAPICooldown]);
    } else {
        self.retryDelay = 0;
        BOOL latestOnly = result == SVCUpdateCheckLatestOnly;
        if (latestOnly) nextCheckDelay = [self remainingAPICooldown];
        NSString *knownVersion = self.availableVersion == nil ? self.installedVersion : self.availableVersion;
        if (result == SVCUpdateCheckAvailable
            || (latestOnly && SVCUpdateVersionIsNewer(version, knownVersion))) {
            self.availableVersion = version;
            [self.defaults setObject:version forKey:SVCAvailableUpdateKey];
        } else if (!latestOnly) {
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
