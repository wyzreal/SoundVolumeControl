#import "UpdateRelease.h"

#include <math.h>

static NSString * const SVCReleaseAPI =
    @"https://api.github.com/repos/wyzreal/SoundVolumeControl/releases/latest";
static NSString * const SVCReleasePage =
    @"https://github.com/wyzreal/SoundVolumeControl/releases/tag/v";

static NSString *SVCUpdateVersion(NSString *tag) {
    NSString *version = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
    NSString *pattern = @"\\A(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\z";
    return [version rangeOfString:pattern options:NSRegularExpressionSearch].location == NSNotFound
        ? nil : version;
}

BOOL SVCUpdateVersionIsNewer(NSString *candidate, NSString *installedVersion) {
    NSString *candidateVersion = SVCUpdateVersion(candidate);
    NSString *currentVersion = SVCUpdateVersion(installedVersion);
    if (candidateVersion == nil || currentVersion == nil) return NO;
    NSArray<NSString *> *candidateParts = [candidateVersion componentsSeparatedByString:@"."];
    NSArray<NSString *> *currentParts = [currentVersion componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < candidateParts.count; i++) {
        NSString *candidatePart = candidateParts[i];
        NSString *currentPart = currentParts[i];
        if (candidatePart.length != currentPart.length) {
            return candidatePart.length > currentPart.length;
        }
        NSComparisonResult order = [candidatePart compare:currentPart options:NSLiteralSearch];
        if (order != NSOrderedSame) return order == NSOrderedDescending;
    }
    return NO;
}

NSURL *SVCUpdateReleasePageURL(NSString *version) {
    NSString *validVersion = SVCUpdateVersion(version);
    return validVersion == nil ? nil
        : [NSURL URLWithString:[SVCReleasePage stringByAppendingString:validVersion]];
}

static NSTimeInterval SVCReleaseRetryAfter(NSHTTPURLResponse *response) {
    NSTimeInterval delay = [response valueForHTTPHeaderField:@"Retry-After"].doubleValue;
    if ([[response valueForHTTPHeaderField:@"X-RateLimit-Remaining"] isEqualToString:@"0"]) {
        NSTimeInterval reset = [response valueForHTTPHeaderField:@"X-RateLimit-Reset"].doubleValue;
        delay = MAX(delay, reset - [NSDate date].timeIntervalSince1970);
    }
    return isfinite(delay) && delay > 0 ? delay : 0;
}

void SVCParseLatestRelease(NSData *data,
                           NSHTTPURLResponse *response,
                           NSString *installedVersion,
                           SVCUpdateCheckCompletion completion) {
    NSInteger status = response.statusCode;
    if (![response.URL.absoluteString isEqualToString:SVCReleaseAPI]) {
        completion(SVCUpdateCheckFailed, nil, @"GitHub redirected the update request.", 0);
        return;
    }
    if (status != 200 && status != 404) {
        NSString *detail = [NSString stringWithFormat:@"GitHub returned HTTP %ld.", (long)status];
        completion(SVCUpdateCheckFailed, nil, detail, SVCReleaseRetryAfter(response));
        return;
    }
    if (SVCUpdateVersion(installedVersion) == nil) {
        completion(SVCUpdateCheckFailed, nil, @"The installed version could not be read.", 0);
        return;
    }
    if (status == 404) {
        completion(SVCUpdateCheckCurrent, nil, nil, 0);
        return;
    }

    id json = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSDictionary *release = [json isKindOfClass:NSDictionary.class] ? json : nil;
    NSString *tag = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : nil;
    NSString *version = [tag hasPrefix:@"v"] ? SVCUpdateVersion(tag) : nil;
    NSArray *assets = release[@"assets"];
    if (version == nil || ![release[@"draft"] isEqual:@NO] || ![release[@"prerelease"] isEqual:@NO]
        || ![assets isKindOfClass:NSArray.class]) {
        completion(SVCUpdateCheckFailed, nil, @"GitHub returned invalid release information.", 0);
        return;
    }
    if (!SVCUpdateVersionIsNewer(version, installedVersion)) {
        completion(SVCUpdateCheckCurrent, nil, nil, 0);
        return;
    }

    NSString *installerName = [NSString stringWithFormat:@"SoundVolumeControl-%@.dmg", version];
    for (id asset in assets) {
        if ([asset isKindOfClass:NSDictionary.class] && [asset[@"name"] isEqual:installerName]
            && [asset[@"state"] isEqual:@"uploaded"] && [asset[@"size"] isKindOfClass:NSNumber.class]
            && [asset[@"size"] doubleValue] > 0) {
            completion(SVCUpdateCheckAvailable, version, nil, 0);
            return;
        }
    }
    completion(SVCUpdateCheckMissingInstaller, version,
        @"This release does not have a compatible installer DMG.", 0);
}

NSURLSessionDataTask *SVCCheckLatestRelease(NSString *installedVersion,
                                          SVCUpdateCheckCompletion completion) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPCookieStorage = nil;
        configuration.URLCredentialStorage = nil;
        configuration.URLCache = nil;
        configuration.timeoutIntervalForResource = 30;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:SVCReleaseAPI]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2026-03-10" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:@"SoundVolumeControl" forHTTPHeaderField:@"User-Agent"];
    return [session dataTaskWithRequest:request
                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error != nil || ![response isKindOfClass:NSHTTPURLResponse.class]) {
            NSString *detail = error != nil ? error.localizedDescription
                : @"GitHub did not return an HTTP response.";
            completion(SVCUpdateCheckFailed, nil, detail, 0);
            return;
        }
        SVCParseLatestRelease(data, (NSHTTPURLResponse *)response, installedVersion, completion);
    }];
}
