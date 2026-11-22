#import "../app/UpdateRelease.h"

#include <assert.h>

static void CheckResponse(NSInteger status, NSDictionary *headers, NSData *data,
                          SVCUpdateCheckResult expected, NSString *expectedVersion,
                          NSTimeInterval expectedDelay) {
    NSURL *url = [NSURL URLWithString:
        @"https://api.github.com/repos/wyzreal/SoundVolumeControl/releases/latest"];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
        statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    __block BOOL called = NO;
    SVCParseLatestRelease(data, response, @"0.8.9",
        ^(SVCUpdateCheckResult result, NSString *version, NSString *detail,
          NSTimeInterval retryAfter) {
            assert(!called);
            called = YES;
            assert(result == expected);
            assert(retryAfter == expectedDelay);
            if (expectedVersion == nil) {
                assert(version == nil);
            } else {
                assert([version isEqualToString:expectedVersion]);
            }
            assert((detail != nil) == (expected == SVCUpdateCheckFailed
                || expected == SVCUpdateCheckMissingInstaller));
        });
    assert(called);
}

static NSData *ReleaseData(NSString *tag, BOOL prerelease, NSArray *assets) {
    return [NSJSONSerialization dataWithJSONObject:@{
        @"tag_name": tag, @"draft": @NO, @"prerelease": @(prerelease), @"assets": assets
    } options:0 error:NULL];
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

static void TestReleaseResults(void) {
    NSArray *installer = @[@{
        @"name": @"SoundVolumeControl-0.8.10.dmg", @"state": @"uploaded", @"size": @2000000
    }];
    CheckResponse(200, nil, ReleaseData(@"v0.8.10", NO, installer),
                  SVCUpdateCheckAvailable, @"0.8.10", 0);
    CheckResponse(200, nil, ReleaseData(@"v0.8.9", NO, @[]),
                  SVCUpdateCheckCurrent, nil, 0);
    CheckResponse(200, nil, ReleaseData(@"v0.8.8", NO, @[]),
                  SVCUpdateCheckCurrent, nil, 0);
    CheckResponse(200, nil, ReleaseData(@"v0.8.10", NO, @[]),
                  SVCUpdateCheckMissingInstaller, @"0.8.10", 0);
    CheckResponse(200, nil, ReleaseData(@"v0.8.11", NO, installer),
                  SVCUpdateCheckMissingInstaller, @"0.8.11", 0);
    CheckResponse(200, nil, ReleaseData(@"v0.8.10", YES, installer),
                  SVCUpdateCheckFailed, nil, 0);
    CheckResponse(200, nil, [@"{}" dataUsingEncoding:NSUTF8StringEncoding],
                  SVCUpdateCheckFailed, nil, 0);
    CheckResponse(404, nil, nil, SVCUpdateCheckCurrent, nil, 0);
    CheckResponse(429, @{@"Retry-After": @"120"}, nil, SVCUpdateCheckFailed, nil, 120);
    CheckResponse(503, nil, nil, SVCUpdateCheckFailed, nil, 0);
}

static void TestRedirectedResponse(void) {
    NSURL *url = [NSURL URLWithString:@"https://example.com/releases/latest"];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
        statusCode:404 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    __block BOOL called = NO;
    SVCParseLatestRelease(nil, response, @"0.8.9",
        ^(SVCUpdateCheckResult result, NSString *version, NSString *detail,
          NSTimeInterval retryAfter) {
            called = YES;
            assert(result == SVCUpdateCheckFailed);
            assert(version == nil && detail != nil && retryAfter == 0);
        });
    assert(called);
}

int main(void) {
    @autoreleasepool {
        TestVersions();
        TestReleaseResults();
        TestRedirectedResponse();
    }
    puts("update-release-tests: PASS");
    return 0;
}
