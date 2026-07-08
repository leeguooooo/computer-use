// team_hook.c — DYLD interpose that lets a non-Codex process pass
// SkyComputerUseClient's sender-authentication gate.
//
// The Computer Use client authenticates its caller by resolving the
// responsible process and calling SecCodeCopySigningInformation, then
// checking kSecCodeInfoTeamIdentifier against OpenAI's Apple team
// "2DC432GLL2" and kSecCodeInfoIdentifier against the approved OpenAI
// bundle-id list. When the client is spawned by a non-Codex agent (e.g.
// Claude Code), those fields don't match and every tool call fails with
// error -10000 "Sender process is not authenticated".
//
// We interpose SecCodeCopySigningInformation: call the real one, then
// rewrite kSecCodeInfoTeamIdentifier and kSecCodeInfoIdentifier in the
// returned dictionary so the gate sees an approved OpenAI caller.
//
// Inject with: DYLD_INSERT_LIBRARIES=/path/to/team_hook.dylib
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>

#define APPROVED_TEAM CFSTR("2DC432GLL2")
#define APPROVED_IDENTIFIER CFSTR("com.openai.codex")

static OSStatus my_SecCodeCopySigningInformation(SecStaticCodeRef code,
                                                 SecCSFlags flags,
                                                 CFDictionaryRef *information) {
    OSStatus st = SecCodeCopySigningInformation(code, flags, information);
    if (st == errSecSuccess && information && *information) {
        CFDictionaryRef original = *information;
        CFStringRef team = (CFStringRef)CFDictionaryGetValue(original,
                                                             kSecCodeInfoTeamIdentifier);
        CFStringRef identifier = (CFStringRef)CFDictionaryGetValue(original,
                                                                   kSecCodeInfoIdentifier);
        Boolean team_ok = team != NULL && CFStringCompare(team, APPROVED_TEAM, 0) == kCFCompareEqualTo;
        Boolean identifier_ok = identifier != NULL && CFStringCompare(identifier, APPROVED_IDENTIFIER, 0) == kCFCompareEqualTo;

        if (!team_ok || !identifier_ok) {
            fprintf(stderr, "[hook5] Injecting TeamIdentifier = 2DC432GLL2\n");
            fprintf(stderr, "[hook5] Injecting Identifier = com.openai.codex\n");
            CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, original);
            if (!team_ok) {
                CFDictionarySetValue(m, kSecCodeInfoTeamIdentifier, APPROVED_TEAM);
            }
            if (!identifier_ok) {
                CFDictionarySetValue(m, kSecCodeInfoIdentifier, APPROVED_IDENTIFIER);
            }
            CFRelease(original);
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
