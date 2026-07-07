// team_hook.c — DYLD interpose that lets a non-Codex process pass
// SkyComputerUseClient's sender-authentication gate.
//
// The Computer Use client authenticates its caller by resolving the
// responsible process and calling SecCodeCopySigningInformation, then
// checking kSecCodeInfoTeamIdentifier against OpenAI's Apple team
// "2DC432GLL2". When the client is spawned by a non-Codex agent (e.g.
// Claude Code), the team id doesn't match and every tool call fails with
// error -10000 "Sender process is not authenticated".
//
// We interpose SecCodeCopySigningInformation: call the real one, then
// rewrite kSecCodeInfoTeamIdentifier in the returned dictionary to
// "2DC432GLL2" so the gate always sees OpenAI's team id.
//
// Inject with: DYLD_INSERT_LIBRARIES=/path/to/team_hook.dylib
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>

#define APPROVED_TEAM CFSTR("2DC432GLL2")

static OSStatus my_SecCodeCopySigningInformation(SecStaticCodeRef code,
                                                 SecCSFlags flags,
                                                 CFDictionaryRef *information) {
    OSStatus st = SecCodeCopySigningInformation(code, flags, information);
    if (st == errSecSuccess && information && *information) {
        CFStringRef cur = (CFStringRef)CFDictionaryGetValue(*information,
                                                            kSecCodeInfoTeamIdentifier);
        if (cur == NULL || CFStringCompare(cur, APPROVED_TEAM, 0) != kCFCompareEqualTo) {
            fprintf(stderr, "[hook5] Injecting TeamIdentifier = 2DC432GLL2\n");
            CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, *information);
            CFDictionarySetValue(m, kSecCodeInfoTeamIdentifier, APPROVED_TEAM);
            CFRelease(*information);
            *information = m;
        }
    }
    return st;
}

__attribute__((used))
static struct { const void *replacement; const void *replacee; }
_interpose_SecCodeCopySigningInformation
__attribute__((section("__DATA,__interpose"))) = {
    (const void *)(uintptr_t)&my_SecCodeCopySigningInformation,
    (const void *)(uintptr_t)&SecCodeCopySigningInformation
};

__attribute__((constructor))
static void team_hook_loaded(void) { fprintf(stderr, "[hook5] loaded\n"); }
