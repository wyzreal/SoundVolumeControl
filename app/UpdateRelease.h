#ifndef SVC_UPDATE_RELEASE_H
#define SVC_UPDATE_RELEASE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SVCUpdateCheckResult) {
    SVCUpdateCheckFailed,
    SVCUpdateCheckCurrent,
    SVCUpdateCheckAvailable,
    SVCUpdateCheckMissingInstaller,
    // Only GitHub's designated Latest release could be checked during a REST cooldown.
    SVCUpdateCheckLatestOnly,
};

typedef void (^SVCUpdateCheckCompletion)(
    SVCUpdateCheckResult result,
    NSString * _Nullable version,
    NSString * _Nullable detail,
    NSTimeInterval retryAfter
);

BOOL SVCUpdateVersionIsNewer(NSString *candidate, NSString *installedVersion);
NSURL * _Nullable SVCUpdateReleasePageURL(NSString *version);
NSURL *SVCUpdateReleasesURL(void);

@protocol SVCUpdateRequest <NSObject>
- (void)resume;
- (void)cancel;
@end

// Returns a suspended request. The completion handler runs on the session queue.
id<SVCUpdateRequest> SVCCheckLatestRelease(NSString *installedVersion,
                                          SVCUpdateCheckCompletion completion);
id<SVCUpdateRequest> SVCCheckPublicLatestRelease(NSString *installedVersion,
                                                NSTimeInterval retryAfter,
                                                SVCUpdateCheckCompletion completion);

id<SVCUpdateRequest> SVCCheckLatestReleaseWithSession(NSURLSession *session,
                                                     NSString *installedVersion,
                                                     SVCUpdateCheckCompletion completion);

NS_ASSUME_NONNULL_END

#endif
