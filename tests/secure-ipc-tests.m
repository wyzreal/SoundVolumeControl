#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "SecureAudio.h"
#include <signal.h>
#include <assert.h>
#include <unistd.h>
#include <sys/stat.h>

static NSMutableArray<NSTask *> *children;
static NSString *temporaryDirectory, *domain, *label;
static BOOL registered;

static NSTask *Start(NSString *path, NSArray<NSString *> *arguments, NSPipe *output) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    if (output != nil) task.standardOutput = output;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "test launch failed: %s\n", error.description.UTF8String);
        exit(1);
    }
    [children addObject:task];
    return task;
}
static int Run(NSString *path, NSArray<NSString *> *arguments) {
    NSTask *task = Start(path, arguments, nil);
    [task waitUntilExit];
    return task.terminationStatus;
}
static void Cleanup(void) {
    @autoreleasepool {
        if (registered) {
            registered = NO;
            (void)Run(@"/bin/launchctl", @[@"bootout", [domain stringByAppendingFormat:@"/%@", label]]);
        }
        for (NSTask *task in [children copy]) {
            if (task.running) { [task terminate]; [task waitUntilExit]; }
        }
        if (temporaryDirectory != nil) {
            [[NSFileManager defaultManager] removeItemAtPath:temporaryDirectory error:NULL];
        }
    }
}
static void Check(BOOL condition, const char *name) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", name); exit(1); }
    printf("PASS: %s\n", name); fflush(stdout);
}

static BOOL MatchesWriterPolicy(NSString *path) {
    SecRequirementRef requirement = NULL;
    Check(SecRequirementCreateWithString(CFSTR(SVC_DRIVER_REQUIREMENT),
          kSecCSDefaultFlags, &requirement) == errSecSuccess, "writer policy compiles");
    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)
        [NSURL fileURLWithPath:path], kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) {
        status = SecStaticCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
        CFRelease(code);
    }
    CFRelease(requirement);
    return status == errSecSuccess;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // This executable is deliberately not the authorized reader build.
        if (argc == 4 && strcmp(argv[1], "--unauthorized") == 0) {
            SVCReaderConnection *reader = SVCReaderOpen(argv[2], argv[3], false, 1);
            if (reader != NULL) { SVCReaderClose(reader); return 1; }
            return 0;
        }
        Check(argc == 1, "arguments");
        children = [NSMutableArray array];
        char template[] = "/private/tmp/svc-secure-test.XXXXXX";
        char *directory = mkdtemp(template);
        Check(directory != NULL, "isolated directory");
        temporaryDirectory = @(directory);
        atexit(Cleanup);
        domain = [NSString stringWithFormat:@"gui/%u", getuid()];
        label = [NSString stringWithFormat:@"org.soundvolumecontrol.test.%d", getpid()];
        NSString *writerName = [label stringByAppendingString:@".writer"];
        NSString *readerName = [label stringByAppendingString:@".reader"];
        NSString *build = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@".build"];
        NSString *broker = [build stringByAppendingPathComponent:@"secure-broker-test"];
        NSString *writer = [build stringByAppendingPathComponent:@"secure-writer-test"];
        NSString *reader = [build stringByAppendingPathComponent:@"secure-reader-test"];
        NSString *policyTool = [build stringByAppendingPathComponent:@"signing-policy"];
        // The mock writer's hash cannot catch a missing real HAL host identity.
        NSString *halHelper = @"/System/Library/Frameworks/CoreAudio.framework/Versions/A/XPCServices/com.apple.audio.Core-Audio-Driver-Service.helper.xpc";
        if ([[NSFileManager defaultManager] fileExistsAtPath:halHelper]) {
            Check(MatchesWriterPolicy(halHelper), "installed Apple HAL helper passes production writer policy");
        } else {
            puts("SKIP: separate Apple HAL helper is absent on this macOS");
        }
        Check(!MatchesWriterPolicy(@"/usr/bin/true"), "unrelated Apple executable denied writer access");
        NSString *impostor = [temporaryDirectory stringByAppendingPathComponent:@"impostor"];
        Check([[NSFileManager defaultManager] copyItemAtPath:writer toPath:impostor error:NULL],
              "copy isolated writer for identity spoof test");
        Check(Run(@"/usr/bin/codesign", @[@"--force", @"--sign", @"-", @"--identifier",
              @"com.apple.audio.Core-Audio-Driver-Service.helper", impostor]) == 0,
              "sign impostor with HAL helper identifier");
        Check(!MatchesWriterPolicy(impostor), "ad-hoc HAL identity spoof denied writer access");
        NSMutableArray<NSString *> *requirements = [NSMutableArray array];
        NSMutableArray<NSString *> *policies = [NSMutableArray array];
        for (NSString *binary in @[broker, writer, reader]) {
            NSString *policy = [temporaryDirectory stringByAppendingPathComponent:binary.lastPathComponent];
            Check(Run(policyTool, @[binary, policy, @"policy"]) == 0, "signing hash generated");
            NSString *value = [NSString stringWithContentsOfFile:policy encoding:NSUTF8StringEncoding error:NULL];
            Check(value.length == 50, "exact signing requirement");
            [requirements addObject:value]; [policies addObject:policy];
        }
        NSDictionary *configuration = @{
            @"Label": label,
            @"ProgramArguments": @[broker, writerName, readerName, policies[2], requirements[1],
                                   [NSString stringWithFormat:@"%u", getuid()]],
            @"MachServices": @{writerName: @YES, readerName: @YES},
            @"StandardErrorPath": [temporaryDirectory stringByAppendingPathComponent:@"broker.log"],
        };
        NSArray *serverArguments = configuration[@"ProgramArguments"];
        Check(chmod(policies[2].fileSystemRepresentation, 0666) == 0, "make isolated policy untrusted");
        Check(Run(broker, [serverArguments subarrayWithRange:NSMakeRange(1, serverArguments.count - 1)]) != 0,
              "writable reader policy rejected before listening");
        Check(chmod(policies[2].fileSystemRepresentation, 0600) == 0, "restore isolated policy permissions");
        NSString *plist = [temporaryDirectory stringByAppendingPathComponent:@"service.plist"];
        Check([configuration writeToFile:plist atomically:YES], "temporary launchd configuration");
        Check(Run(@"/bin/launchctl", @[@"bootstrap", domain, plist]) == 0, "temporary test service registration");
        registered = YES;
        NSTask *writerTask = Start(writer, @[writerName, requirements[0]], nil);
        Check(Run(reader, @[readerName, requirements[0], @"read"]) == 0,
              "authenticated separate-process driver audio");
        usleep(100000);
        Check(Run([build stringByAppendingPathComponent:@"secure-ipc-tests"],
            @[@"--unauthorized", readerName, requirements[0]]) == 0,
            "wrong reader signature rejected");
        Check(Run(reader, @[writerName, requirements[0], @"deny"]) == 0,
              "reader cannot impersonate writer");
        Check(Run(reader, @[readerName, requirements[1], @"deny"]) == 0,
              "wrong server signature rejected");
        usleep(100000);
        NSPipe *revokeOutput = [NSPipe pipe];
        NSTask *revokeReader = Start(reader, @[readerName, requirements[0], @"revoke"], revokeOutput);
        NSData *ready = revokeOutput.fileHandleForReading.availableData;
        NSString *line = [[NSString alloc] initWithData:ready encoding:NSUTF8StringEncoding];
        Check([line containsString:@"READY"], "authorized reader ready for revocation");
        Check(kill(writerTask.processIdentifier, SIGUSR1) == 0, "simulate session change in test broker");
        [revokeReader waitUntilExit];
        Check(revokeReader.terminationStatus == 0, "session change disconnects reader and freezes old buffer");
        Check(Run(reader, @[readerName, requirements[0], @"deny"]) == 0,
              "signed reader outside active session rejected");
        puts("secure-ipc-tests: PASS (real XPC authentication and driver transport; no audio device changes)");
    }
    return 0;
}
