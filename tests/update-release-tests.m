#import "../app/UpdateRelease.h"

#include <assert.h>

static NSString * const SVCFixtureEndpoint =
    @"https://api.github.com/repos/wyzreal/SoundVolumeControl/releases";
static NSString * const SVCFixtureReleases = @"https://github.com/wyzreal/SoundVolumeControl/releases";
static NSArray<NSDictionary *> *SVCReleaseFixtures;
static NSUInteger SVCReleaseFixtureRequests;

@interface SVCFixtureProtocol : NSURLProtocol
@end

@implementation SVCFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    (void)request;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSUInteger index;
    NSDictionary *fixture;
    @synchronized (SVCFixtureProtocol.class) {
        index = SVCReleaseFixtureRequests++;
        assert(index < SVCReleaseFixtures.count);
        fixture = SVCReleaseFixtures[index];
    }

    NSString *expectedURL = fixture[@"requestURL"];
    BOOL isHead = expectedURL != nil;
    if (!isHead) {
        expectedURL = [NSString stringWithFormat:@"%@?per_page=100&page=%lu",
            SVCFixtureEndpoint, (unsigned long)(index + 1)];
    }
    assert([self.request.HTTPMethod isEqualToString:isHead ? @"HEAD" : @"GET"]);
    assert([self.request.URL.absoluteString isEqualToString:expectedURL]);
    if (fixture[@"error"] != nil) {
        [self.client URLProtocol:self didFailWithError:fixture[@"error"]];
        return;
    }
    NSURL *responseURL = fixture[@"url"] != nil
        ? [NSURL URLWithString:fixture[@"url"]] : self.request.URL;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:responseURL
        statusCode:[fixture[@"status"] integerValue] HTTPVersion:@"HTTP/1.1"
        headerFields:fixture[@"headers"]];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (!isHead) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:fixture[@"body"] options:0 error:NULL];
        [self.client URLProtocol:self didLoadData:data];
    }
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}
@end

static NSDictionary *Page(NSInteger status, NSDictionary *headers, id body) {
    return @{@"status": @(status), @"headers": headers, @"body": body};
}

static NSDictionary *LatestPage(NSString *version) {
    return @{
        @"requestURL": [SVCFixtureReleases stringByAppendingString:@"/latest"],
        @"url": [SVCFixtureReleases stringByAppendingFormat:@"/tag/v%@", version],
        @"status": @200
    };
}

static NSDictionary *AssetHead(NSString *version, NSInteger status, NSString *finalURL,
                               NSDictionary *headers) {
    return @{
        @"requestURL": [SVCFixtureReleases stringByAppendingFormat:
            @"/download/v%@/SoundVolumeControl-%@.dmg", version, version],
        @"url": finalURL, @"status": @(status), @"headers": headers
    };
}

static NSDictionary *Release(NSString *version, BOOL prerelease, BOOL draft, NSArray *assets) {
    return @{
        @"tag_name": [@"v" stringByAppendingString:version], @"draft": @(draft),
        @"prerelease": @(prerelease), @"assets": assets
    };
}

static NSArray *Installer(NSString *version) {
    return @[@{
        @"name": [NSString stringWithFormat:@"SoundVolumeControl-%@.dmg", version],
        @"state": @"uploaded", @"size": @2000000
    }];
}

static void CheckResponse(NSArray<NSDictionary *> *fixtures, SVCUpdateCheckResult expected,
                          NSString *expectedVersion, NSTimeInterval expectedDelay) {
    @synchronized (SVCFixtureProtocol.class) {
        SVCReleaseFixtures = fixtures;
        SVCReleaseFixtureRequests = 0;
    }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[SVCFixtureProtocol.class];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    id<SVCUpdateRequest> request = SVCCheckLatestReleaseWithSession(session, @"0.8.9",
        ^(SVCUpdateCheckResult result, NSString *version, NSString *detail,
          NSTimeInterval retryAfter) {
            assert(result == expected);
            assert(retryAfter == expectedDelay);
            assert(expectedVersion == nil ? version == nil : [version isEqualToString:expectedVersion]);
            if (expected == SVCUpdateCheckFailed || expected == SVCUpdateCheckMissingInstaller) {
                assert(detail.length > 0);
            } else {
                assert(detail == nil);
            }
            dispatch_semaphore_signal(done);
        });
    [request resume];
    [request resume];
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    [session finishTasksAndInvalidate];
    @synchronized (SVCFixtureProtocol.class) {
        assert(SVCReleaseFixtureRequests == fixtures.count);
    }
}

static void TestVersions(void) {
    assert(SVCUpdateVersionIsNewer(@"v0.8.10", @"0.8.9"));
    assert(SVCUpdateVersionIsNewer(@"1.0.0", @"0.99.999"));
    assert(!SVCUpdateVersionIsNewer(@"v0.8.8", @"0.8.9"));
    assert(!SVCUpdateVersionIsNewer(@"v0.8.9", @"0.8.9"));
    assert(!SVCUpdateVersionIsNewer(@"v0.08.10", @"0.8.9"));
    assert(!SVCUpdateVersionIsNewer(@"v0.8.10-rc.1", @"0.8.9"));
    assert(!SVCUpdateVersionIsNewer(@"v0.8.10", @""));
    assert(SVCUpdateReleasePageURL(@"0.8.10/../../") == nil);
    assert([SVCUpdateReleasePageURL(@"0.8.10").absoluteString isEqualToString:
        @"https://github.com/wyzreal/SoundVolumeControl/releases/tag/v0.8.10"]);
}

static void TestReleaseSelection(void) {
    NSDictionary *first = Release(@"0.9.0", NO, NO, Installer(@"0.9.0"));
    NSDictionary *second = Release(@"0.9.1", NO, NO, Installer(@"0.9.1"));
    NSDictionary *third = Release(@"0.9.2", NO, NO, Installer(@"0.9.2"));
    NSDictionary *tenth = Release(@"0.9.10", NO, NO, Installer(@"0.9.10"));
    NSDictionary *prerelease = Release(@"0.9.11", YES, NO, Installer(@"0.9.11"));
    NSDictionary *draft = Release(@"0.9.12", NO, YES, Installer(@"0.9.12"));
    NSDictionary *missing = Release(@"0.9.12", NO, NO, @[]);
    NSDictionary *wrongInstaller = Release(@"0.9.11", NO, NO, Installer(@"0.9.1"));

    CheckResponse(@[Page(200, @{}, @[first, third, second])],
                  SVCUpdateCheckAvailable, @"0.9.2", 0);
    CheckResponse(@[Page(200, @{}, @[prerelease, tenth, third, draft])],
                  SVCUpdateCheckAvailable, @"0.9.10", 0);
    CheckResponse(@[Page(200, @{}, @[missing, wrongInstaller, second, first])],
                  SVCUpdateCheckAvailable, @"0.9.1", 0);
    CheckResponse(@[Page(200, @{}, @[missing, prerelease, wrongInstaller])],
                  SVCUpdateCheckMissingInstaller, @"0.9.12", 0);
    CheckResponse(@[Page(200, @{}, @[Release(@"0.8.9", NO, NO, @[]),
                                   Release(@"0.8.8", NO, NO, @[]), prerelease, draft])],
                  SVCUpdateCheckCurrent, nil, 0);
    CheckResponse(@[Page(200, @{}, @[])], SVCUpdateCheckCurrent, nil, 0);
}

static void TestPagination(void) {
    NSDictionary *pageOne = Page(200, @{@"Link":
        @"<https://api.github.com/repositories/123/releases?per_page=100&page=2>; rel=\"next\", "
        @"<https://api.github.com/repositories/123/releases?per_page=100&page=2>; rel=\"last\""},
        @[Release(@"0.9.0", NO, NO, Installer(@"0.9.0"))]);
    NSDictionary *pageTwo = Page(200, @{@"Link":
        @"<https://api.github.com/repositories/123/releases?per_page=100&page=1>; rel=\"prev\""},
        @[Release(@"0.9.2", NO, NO, Installer(@"0.9.2")),
          Release(@"0.9.1", NO, NO, Installer(@"0.9.1"))]);
    CheckResponse(@[pageOne, pageTwo], SVCUpdateCheckAvailable, @"0.9.2", 0);
    CheckResponse(@[pageOne, Page(429, @{@"Retry-After": @"120"}, @{}), LatestPage(@"0.8.9")],
                  SVCUpdateCheckLatestOnly, @"0.8.9", 120);

    CheckResponse(@[Page(200, @{@"Link":
        @"<https://api.github.com/repositories/123/releases?page=1>; rel=\"next\""}, @[])],
                  SVCUpdateCheckFailed, nil, 0);
    CheckResponse(@[Page(200, @{@"Link":
        @"<https://example.com/releases?page=2>; rel=\"next\""}, @[])],
                  SVCUpdateCheckFailed, nil, 0);
}

static void TestInvalidResponses(void) {
    CheckResponse(@[Page(200, @{}, @{})], SVCUpdateCheckFailed, nil, 0);
    CheckResponse(@[Page(404, @{}, @{})], SVCUpdateCheckFailed, nil, 0);
    CheckResponse(@[Page(503, @{}, @{})], SVCUpdateCheckFailed, nil, 0);
    CheckResponse(@[@{@"status": @200, @"headers": @{}, @"body": @[],
                      @"url": @"https://example.com/releases"}],
                  SVCUpdateCheckFailed, nil, 0);
}

static void TestRateLimitedReleaseCheck(void) {
    NSDictionary *primary = Page(403, @{@"X-RateLimit-Remaining": @"0", @"Retry-After": @"90"},
        @{@"message": @"API rate limit exceeded"});
    NSDictionary *secondary = Page(403, @{@"Retry-After": @"120"},
        @{@"message": @"You have exceeded a secondary rate limit."});
    NSDictionary *limited = Page(429, @{@"Retry-After": @"120"}, @{});
    NSString *assetURL = @"https://release-assets.githubusercontent.com/github-production-release-asset/test";
    NSDictionary *latest = LatestPage(@"0.9.1");
    NSDictionary *asset = AssetHead(@"0.9.1", 200, assetURL, @{@"Content-Length": @"2067227"});

    CheckResponse(@[primary, latest, asset], SVCUpdateCheckLatestOnly, @"0.9.1", 90);
    CheckResponse(@[secondary, latest, asset], SVCUpdateCheckLatestOnly, @"0.9.1", 120);
    CheckResponse(@[limited, LatestPage(@"0.8.8")], SVCUpdateCheckLatestOnly, @"0.8.8", 120);
    CheckResponse(@[Page(403, @{@"X-RateLimit-Remaining": @"56"}, @{@"message": @"Forbidden"})],
                  SVCUpdateCheckFailed, nil, 0);

    for (NSDictionary *badAsset in @[
        AssetHead(@"0.9.1", 404, assetURL, @{}),
        AssetHead(@"0.9.1", 200, assetURL, @{@"Content-Length": @"0"}),
        AssetHead(@"0.9.1", 200, @"https://example.com/installer", @{@"Content-Length": @"123"}),
    ]) {
        CheckResponse(@[limited, latest, badAsset], SVCUpdateCheckFailed, nil, 120);
    }
    NSString *latestURL = latest[@"requestURL"];
    for (NSDictionary *badPage in @[
        LatestPage(@"0.9.1-rc.1"),
        @{@"requestURL": latestURL, @"status": @200, @"url": @"https://github.com/login"},
        @{@"requestURL": latestURL, @"error": [NSError errorWithDomain:NSURLErrorDomain
                code:NSURLErrorTimedOut userInfo:nil]},
    ]) {
        CheckResponse(@[limited, badPage], SVCUpdateCheckFailed, nil, 120);
    }
}

int main(void) {
    @autoreleasepool {
        TestVersions();
        TestReleaseSelection();
        TestPagination();
        TestInvalidResponses();
        TestRateLimitedReleaseCheck();
    }
    puts("update-release-tests: PASS");
    return 0;
}
