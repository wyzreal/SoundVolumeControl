#import "UpdateRelease.h"

#include <math.h>

static NSString * const SVCReleaseAPI =
    @"https://api.github.com/repos/wyzreal/SoundVolumeControl/releases";
static NSString * const SVCReleasePage =
    @"https://github.com/wyzreal/SoundVolumeControl/releases/tag/v";

NSURL *SVCUpdateReleasesURL(void) {
    return [NSURL URLWithString:@"https://github.com/wyzreal/SoundVolumeControl/releases"];
}

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

static BOOL SVCReleaseHasInstaller(NSString *version, NSArray *assets) {
    NSString *installerName = [NSString stringWithFormat:@"SoundVolumeControl-%@.dmg", version];
    for (id asset in assets) {
        if ([asset isKindOfClass:NSDictionary.class] && [asset[@"name"] isEqual:installerName]
            && [asset[@"state"] isEqual:@"uploaded"] && [asset[@"size"] isKindOfClass:NSNumber.class]
            && [asset[@"size"] doubleValue] > 0) {
            return YES;
        }
    }
    return NO;
}

static BOOL SVCReadNextPage(NSHTTPURLResponse *response, NSUInteger page, BOOL *hasNextPage) {
    *hasNextPage = NO;
    NSString *link = [response valueForHTTPHeaderField:@"Link"];
    if (![link containsString:@"rel=\"next\""]) return YES;

    NSRegularExpression *pattern = [NSRegularExpression
        regularExpressionWithPattern:@"<([^>]+)>[ \\t]*;[ \\t]*rel=\"next\""
        options:0 error:NULL];
    NSTextCheckingResult *match = [pattern firstMatchInString:link options:0
        range:NSMakeRange(0, link.length)];
    if (match == nil || page == NSUIntegerMax) return NO;

    NSURLComponents *next = [NSURLComponents componentsWithString:
        [link substringWithRange:[match rangeAtIndex:1]]];
    if (![next.scheme isEqualToString:@"https"]
        || ![next.host isEqualToString:@"api.github.com"]) return NO;

    NSString *expectedPage = [NSString stringWithFormat:@"%lu", (unsigned long)(page + 1)];
    for (NSURLQueryItem *item in next.queryItems) {
        if ([item.name isEqualToString:@"page"]) {
            if (*hasNextPage || ![item.value isEqualToString:expectedPage]) return NO;
            *hasNextPage = YES;
        }
    }
    return *hasNextPage;
}

@interface SVCReleaseRequest : NSObject <SVCUpdateRequest>
- (instancetype)initWithSession:(NSURLSession *)session
                installedVersion:(NSString *)installedVersion
                      completion:(SVCUpdateCheckCompletion)completion;
@end

@implementation SVCReleaseRequest {
    NSTimeInterval _publicRetryAfter;
    NSURLSession *_session;
    NSString *_installedVersion;
    SVCUpdateCheckCompletion _completion;
    NSURLSessionDataTask *_task;
    NSString *_highestRelease;
    NSString *_highestInstallableRelease;
}

- (instancetype)initWithSession:(NSURLSession *)session
                installedVersion:(NSString *)installedVersion
                      completion:(SVCUpdateCheckCompletion)completion {
    self = [super init];
    if (self != nil) {
        _session = session;
        _installedVersion = [installedVersion copy];
        _completion = [completion copy];
    }
    return self;
}

- (void)usePublicReleaseForDelay:(NSTimeInterval)delay {
    _publicRetryAfter = delay;
}

- (void)requestPublicRelease:(NSString *)version {
    NSURL *url = version == nil ? [SVCUpdateReleasesURL() URLByAppendingPathComponent:@"latest"]
        : [SVCUpdateReleasesURL() URLByAppendingPathComponent:
            [NSString stringWithFormat:@"download/v%@/SoundVolumeControl-%@.dmg", version, version]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    request.HTTPMethod = @"HEAD";
    @synchronized (self) {
        if (_completion == nil) return;
        _task = [_session dataTaskWithRequest:request completionHandler:
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                (void)data;
                NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
                    ? (NSHTTPURLResponse *)response : nil;
                if (error == nil && http.statusCode == 200 && SVCUpdateVersion(_installedVersion) != nil) {
                    if (version == nil) {
                        NSString *tag = response.URL.lastPathComponent;
                        NSString *latest = SVCUpdateVersion(tag);
                        if (latest != nil && [response.URL isEqual:SVCUpdateReleasePageURL(latest)]) {
                            if (SVCUpdateVersionIsNewer(latest, _installedVersion)) {
                                [self requestPublicRelease:latest];
                            } else {
                                [self finish:SVCUpdateCheckLatestOnly version:latest detail:nil retryAfter:_publicRetryAfter];
                            }
                            return;
                        }
                    } else if (([response.URL isEqual:url] ||
                                ([response.URL.scheme isEqual:@"https"] &&
                                 [response.URL.host isEqual:@"release-assets.githubusercontent.com"]))
                               && [http valueForHTTPHeaderField:@"Content-Length"].longLongValue > 0) {
                        [self finish:SVCUpdateCheckLatestOnly version:version detail:nil retryAfter:_publicRetryAfter];
                        return;
                    }
                }
                [self finish:SVCUpdateCheckFailed version:nil
                      detail:@"GitHub is limiting update checks, and the public release could not be verified. You can view releases in your browser."
                  retryAfter:_publicRetryAfter];
            }];
        [_task resume];
    }
}

- (void)resume {
    @synchronized (self) {
        if (_task != nil || _completion == nil) return;
        if (_publicRetryAfter > 0) [self requestPublicRelease:nil];
        else [self requestPage:1];
    }
}

- (void)cancel {
    @synchronized (self) {
        _completion = nil;
        [_task cancel];
        _task = nil;
    }
}

- (void)finish:(SVCUpdateCheckResult)result
       version:(NSString *)version
        detail:(NSString *)detail
    retryAfter:(NSTimeInterval)retryAfter {
    SVCUpdateCheckCompletion completion;
    @synchronized (self) {
        completion = _completion;
        _completion = nil;
        _task = nil;
    }
    if (completion != nil) completion(result, version, detail, retryAfter);
}

- (BOOL)recordPageData:(NSData *)data {
    id json = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:NSArray.class]) return NO;

    for (id release in json) {
        if (![release isKindOfClass:NSDictionary.class]) return NO;
        if ([release[@"draft"] isEqual:@YES] || [release[@"prerelease"] isEqual:@YES]) continue;
        if (![release[@"draft"] isEqual:@NO] || ![release[@"prerelease"] isEqual:@NO]
            || ![release[@"tag_name"] isKindOfClass:NSString.class]) return NO;

        NSString *tag = release[@"tag_name"];
        NSString *version = [tag hasPrefix:@"v"] ? SVCUpdateVersion(tag) : nil;
        if (version == nil || !SVCUpdateVersionIsNewer(version, _installedVersion)) continue;

        NSArray *assets = release[@"assets"];
        if (![assets isKindOfClass:NSArray.class]) return NO;
        if (_highestRelease == nil || SVCUpdateVersionIsNewer(version, _highestRelease)) {
            _highestRelease = version;
        }
        if ((_highestInstallableRelease == nil
             || SVCUpdateVersionIsNewer(version, _highestInstallableRelease))
            && SVCReleaseHasInstaller(version, assets)) {
            _highestInstallableRelease = version;
        }
    }
    return YES;
}

- (void)requestPage:(NSUInteger)page {
    // Always request pages from the same repository endpoint. GitHub can
    // express the next Link URL with a numeric repository path.
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?per_page=100&page=%lu",
        SVCReleaseAPI, (unsigned long)page]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2026-03-10" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:@"SoundVolumeControl" forHTTPHeaderField:@"User-Agent"];
    @synchronized (self) {
        if (_completion == nil) return;
        _task = [_session dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                [self receivedPage:page url:url data:data response:response error:error];
            }];
        [_task resume];
    }
}

- (void)receivedPage:(NSUInteger)page
                url:(NSURL *)url
               data:(NSData *)data
           response:(NSURLResponse *)response
              error:(NSError *)error {
    if (error != nil || ![response isKindOfClass:NSHTTPURLResponse.class]) {
        NSString *detail = error != nil ? error.localizedDescription
            : @"GitHub did not return an HTTP response.";
        [self finish:SVCUpdateCheckFailed version:nil detail:detail retryAfter:0];
        return;
    }
    if (![response.URL isEqual:url]) {
        [self finish:SVCUpdateCheckFailed version:nil
                detail:@"GitHub redirected the update request." retryAfter:0];
        return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    if (http.statusCode == 403 || http.statusCode == 429) {
        id body = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        id message = [body isKindOfClass:NSDictionary.class] ? body[@"message"] : nil;
        NSTimeInterval delay = SVCReleaseRetryAfter(http);
        if (http.statusCode == 429 || delay > 0
            || [[http valueForHTTPHeaderField:@"X-RateLimit-Remaining"] isEqual:@"0"]
            || ([message isKindOfClass:NSString.class] && [message localizedCaseInsensitiveContainsString:@"rate limit"])) {
            _publicRetryAfter = delay > 0 ? delay : 60;
            [self requestPublicRelease:nil];
            return;
        }
    }
    if (http.statusCode != 200) {
        NSString *detail = [NSString stringWithFormat:@"GitHub returned HTTP %ld.", (long)http.statusCode];
        [self finish:SVCUpdateCheckFailed version:nil detail:detail retryAfter:SVCReleaseRetryAfter(http)];
        return;
    }

    BOOL hasNextPage;
    if (SVCUpdateVersion(_installedVersion) == nil) {
        [self finish:SVCUpdateCheckFailed version:nil
                detail:@"The installed version could not be read." retryAfter:0];
    } else if (![self recordPageData:data] || !SVCReadNextPage(http, page, &hasNextPage)) {
        [self finish:SVCUpdateCheckFailed version:nil
                detail:@"GitHub returned invalid release information." retryAfter:0];
    } else if (hasNextPage) {
        [self requestPage:page + 1];
    } else if (_highestInstallableRelease != nil) {
        [self finish:SVCUpdateCheckAvailable version:_highestInstallableRelease detail:nil retryAfter:0];
    } else if (_highestRelease != nil) {
        [self finish:SVCUpdateCheckMissingInstaller version:_highestRelease
                detail:@"This release does not have a compatible installer DMG." retryAfter:0];
    } else {
        [self finish:SVCUpdateCheckCurrent version:nil detail:nil retryAfter:0];
    }
}
@end

id<SVCUpdateRequest> SVCCheckLatestReleaseWithSession(NSURLSession *session,
                                                     NSString *installedVersion,
                                                     SVCUpdateCheckCompletion completion) {
    return [[SVCReleaseRequest alloc] initWithSession:session
                                     installedVersion:installedVersion completion:completion];
}

static NSURLSession *SVCUpdateSession(void) {
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

    return session;
}

id<SVCUpdateRequest> SVCCheckLatestRelease(NSString *installedVersion, SVCUpdateCheckCompletion completion) {
    return SVCCheckLatestReleaseWithSession(SVCUpdateSession(), installedVersion, completion);
}

id<SVCUpdateRequest> SVCCheckPublicLatestRelease(NSString *installedVersion, NSTimeInterval retryAfter,
                                                 SVCUpdateCheckCompletion completion) {
    SVCReleaseRequest *request = [[SVCReleaseRequest alloc] initWithSession:SVCUpdateSession()
        installedVersion:installedVersion completion:completion];
    [request usePublicReleaseForDelay:retryAfter];
    return request;
}
