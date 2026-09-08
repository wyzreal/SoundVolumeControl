#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Build-time tool. Generates policy from the actual signed executable, without
// parsing human-oriented codesign stderr or pinning an ad-hoc identifier.
int main(int argc, char **argv) {
    if (argc != 4) return 64; // signed binary, destination, "plist" or "policy"
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL,
        (const UInt8 *)argv[1], strlen(argv[1]), false);
    SecStaticCodeRef code = NULL;
    CFDictionaryRef info = NULL;
    if (SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code) != errSecSuccess ||
        SecStaticCodeCheckValidity(code, kSecCSStrictValidate, NULL) != errSecSuccess ||
        SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) != errSecSuccess) return 1;
    CFDataRef hash = CFDictionaryGetValue(info, kSecCodeInfoUnique);
    if (hash == NULL || CFGetTypeID(hash) != CFDataGetTypeID() || CFDataGetLength(hash) != 20) return 1;
    char requirement[51] = "cdhash H\"";
    const UInt8 *bytes = CFDataGetBytePtr(hash);
    for (size_t i = 0; i < 20; ++i) snprintf(requirement + 9 + i * 2, 3, "%02x", bytes[i]);
    requirement[49] = '"'; requirement[50] = 0;
    if (strcmp(argv[3], "plist") == 0) {
        FILE *input = fopen(argv[2], "rb");
        if (input == NULL) return 1;
        char buffer[16384];
        size_t count = fread(buffer, 1, sizeof(buffer), input);
        fclose(input);
        if (count == sizeof(buffer)) return 1;
        CFDataRef data = CFDataCreate(NULL, (const UInt8 *)buffer, count);
        CFMutableDictionaryRef plist = (CFMutableDictionaryRef)CFPropertyListCreateWithData(NULL,
            data, kCFPropertyListMutableContainers, NULL, NULL);
        if (plist == NULL || CFGetTypeID(plist) != CFDictionaryGetTypeID()) return 1;
        CFStringRef value = CFStringCreateWithCString(NULL, requirement, kCFStringEncodingUTF8);
        CFDictionarySetValue(plist, CFSTR("SVCBrokerRequirement"), value);
        CFDataRef output = CFPropertyListCreateData(NULL, plist, kCFPropertyListXMLFormat_v1_0, 0, NULL);
        FILE *destination = fopen(argv[2], "wb");
        if (destination == NULL || output == NULL) return 1;
        size_t size = (size_t)CFDataGetLength(output);
        bool ok = fwrite(CFDataGetBytePtr(output), 1, size, destination) == size;
        if (fclose(destination) != 0 || !ok) return 1;
    } else if (strcmp(argv[3], "policy") == 0) {
        FILE *destination = fopen(argv[2], "wb");
        if (destination == NULL) return 1;
        bool ok = fwrite(requirement, 1, 50, destination) == 50;
        if (fclose(destination) != 0 || !ok) return 1;
    } else return 64;
    CFRelease(info); CFRelease(code); CFRelease(url);
    return 0;
}
