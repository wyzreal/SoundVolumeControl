#import <Foundation/Foundation.h>

#import "UpdateRelease.h"

NS_ASSUME_NONNULL_BEGIN

// Call and observe the checker on the main thread.
@interface SVCUpdateChecker : NSObject

- (instancetype)initWithVersion:(NSString *)version defaults:(NSUserDefaults *)defaults;

@property(nonatomic, readonly) BOOL automaticChecks;
@property(nonatomic, readonly, getter=isChecking) BOOL checking;
@property(nonatomic, readonly, nullable) NSString *availableVersion;
@property(nonatomic, copy, nullable) void (^stateChanged)(void);
@property(nonatomic, copy, nullable) void (^manualCheckFinished)(
    SVCUpdateCheckResult result, NSString * _Nullable version, NSString * _Nullable detail);

- (void)start;
- (void)stop;
- (void)checkManually;
- (void)setAutomaticChecksEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
