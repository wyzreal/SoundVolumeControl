#ifndef SVC_UPDATE_RELEASE_H
#define SVC_UPDATE_RELEASE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SVCUpdateCheckResult) {
    SVCUpdateCheckFailed,
    SVCUpdateCheckCurrent,
    SVCUpdateCheckAvailable,
    SVCUpdateCheckMissingInstaller,
};

typedef void (^SVCUpdateCheckCompletion)(
    SVCUpdateCheckResult result,
    NSString * _Nullable version,
    NSString * _Nullable detail,
    NSTimeInterval retryAfter
);

BOOL SVCUpdateVersionIsNewer(NSString *candidate, NSString *installedVersion);
NSURL * _Nullable SVCUpdateReleasePageURL(NSString *version);

// Returns a suspended task. The completion handler runs on the session queue.
NSURLSessionDataTask *SVCCheckLatestRelease(NSString *installedVersion,
                                          SVCUpdateCheckCompletion completion);

// Called by the HTTP client and by fixtures with recorded response shapes.
void SVCParseLatestRelease(NSData * _Nullable data,
                           NSHTTPURLResponse *response,
                           NSString *installedVersion,
                           SVCUpdateCheckCompletion completion);

NS_ASSUME_NONNULL_END

#endif
