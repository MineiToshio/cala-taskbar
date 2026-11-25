// cala-keychain: the only code that touches Cala's Mail app passwords in the Keychain (service "Cala Mail").
//
// Why a separate binary: Cala is signed ad-hoc, so every build has a new cdhash, and the login keychain ties each item
// to the cdhash of the program that may read it. Every update therefore meant a Mac-password prompt per account. This
// helper is built and signed ONCE (scripts/build-keychain-helper.sh), committed as packaging/Helpers/cala-keychain and
// copied into Cala.app/Contents/Helpers without re-signing, so its cdhash, and the Keychain's trust in it, survive
// every Cala update. Change this file only when you really must: a new binary means one more prompt for every user.
//
// Protocol (stdin/stdout only; secrets never go through argv or the environment):
//   stdin line 1: get | set | delete
//   stdin line 2: account id
//   set only:     everything after line 2, up to EOF, is the password (bytes stored as-is)
//   get:          on success the password bytes are written to stdout, nothing else
// Exit codes: 0 ok, 1 not found, 2 denied/cancelled (errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed),
//             3 other Keychain error (OSStatus on stderr), 64 bad request,
//             77 caller is not this bundle's app (wrong identity, exec'd parent, or Cala.app replaced while running),
//             78 caller could not be verified (an anti-race hint was unavailable; only with a Team ID, see below).
//
// Caller check (before the request is read). Mandatory in every mode; any failure gives 77:
//   - this helper is <bundle>/Contents/Helpers/cala-keychain, its own running code is valid
//     (SecCodeCheckValidity(self)), and that bundle has a CFBundleIdentifier;
//   - the parent's code can be located and SecCodeCheckValidity(parent, requirement) succeeds, where the requirement is
//     `identifier "<that CFBundleIdentifier>"` plus, when this helper carries a Team ID (Developer ID builds),
//     `anchor apple generic and certificate leaf[subject.OU] = "<that team>"`;
//   - the parent is that bundle's main executable (its path resolves to the same bundle).
// Anti-race hints: the parent's audit token (task name port) must carry the pid version the kernel recorded when it
// forked us (private proc_pidinfo flavor 17, trusted only when its layout checks out against our own audit token), and
// it must not change during the check; an exec() after spawning gives 77. Without a Team ID these hints are skipped
// when the OS cannot provide them (pid lookup instead), so an OS change never locks out the real Cala; with a Team ID
// such a failure gives 78.
// What it protects: ad-hoc (the free build), nothing against a local attacker, who can sign any program with any
// identifier and copy this helper beside it; it stops accidental and casual callers. Developer ID: only code signed by
// that team is served; code already running as Cala is not stopped.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <libproc.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { EXIT_FOUND_OK = 0, EXIT_NOT_FOUND = 1, EXIT_DENIED = 2, EXIT_KEYCHAIN = 3, EXIT_BAD_REQUEST = 64, EXIT_REFUSED = 77,
       EXIT_UNVERIFIED = 78 };

#ifdef CALA_KEYCHAIN_TEST
// Test builds only (scripts/build-keychain-helper.sh --test): a throwaway service in a throwaway keychain, no caller
// check. None of this is compiled into the shipped binary.
#define SERVICE "Cala Helper Test"
#else
#define SERVICE "Cala Mail"
#endif
#define MAX_REQUEST (64 * 1024)
#define MAX_ID 512

static int fail(int code, const char *what, OSStatus status) {
    if (what && status) fprintf(stderr, "cala-keychain: %s (OSStatus %d)\n", what, (int)status);
    else if (what) fprintf(stderr, "cala-keychain: %s\n", what);
    return code;
}

static int keychain_exit(const char *what, OSStatus status) {
    if (status == errSecItemNotFound) return EXIT_NOT_FOUND;
    if (status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed)
        return fail(EXIT_DENIED, what, status);
    return fail(EXIT_KEYCHAIN, what, status);
}

#ifndef CALA_KEYCHAIN_TEST
// PROC_PIDUNIQIDENTIFIERINFO is not in the public SDK; layout from xnu bsd/sys/proc_info_private.h
// (struct proc_uniqidentifierinfo). proc_pidinfo returns its size only when the kernel knows the flavor.
#define CALA_PROC_PIDUNIQIDENTIFIERINFO 17
struct cala_uniqidentifierinfo {
    uint8_t p_uuid[16];
    uint64_t p_uniqueid;
    uint64_t p_puniqueid;
    int32_t p_idversion;
    int32_t p_orig_ppidversion; // the parent's pid version when it forked us
    uint64_t p_reserve2;
    uint64_t p_reserve3;
};

// Path of the bundle that contains this helper: <bundle>/Contents/Helpers/cala-keychain.
static int own_bundle(char out[PATH_MAX]) {
    char raw[PATH_MAX];
    uint32_t size = sizeof raw;
    if (_NSGetExecutablePath(raw, &size) != 0 || !realpath(raw, out)) return 0;
    static const char *const expected[] = { "cala-keychain", "Helpers", "Contents" };
    for (int i = 0; i < 3; i++) {
        char *slash = strrchr(out, '/');
        if (!slash || slash == out || strcmp(slash + 1, expected[i]) != 0) return 0;
        *slash = 0;
    }
    return 1;
}

static int safe_token(const char *s, const char *extra) {
    if (!*s) return 0;
    for (; *s; s++)
        if (!((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z') || (*s >= '0' && *s <= '9') || strchr(extra, *s)))
            return 0;
    return 1;
}

// CFBundleIdentifier of the bundle at `path` (its Contents/Info.plist, sealed by the app's signature).
static int bundle_identifier(const char *path, char out[256]) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), true);
    if (!url) return 0;
    CFBundleRef bundle = CFBundleCreate(NULL, url);
    CFRelease(url);
    if (!bundle) return 0;
    CFStringRef id = CFBundleGetIdentifier(bundle);
    int ok = id && CFStringGetCString(id, out, 256, kCFStringEncodingUTF8) && safe_token(out, ".-");
    CFRelease(bundle);
    return ok;
}

// This helper's own Team ID, if it has one (Developer ID signed); 0 = none (ad-hoc), -1 = unknown. Only after the
// running code validates: replacing the file on disk mid-run would otherwise report the new file's signature.
static int own_team(char out[64]) {
    SecCodeRef self = NULL;
    SecStaticCodeRef staticSelf = NULL;
    CFDictionaryRef info = NULL;
    int found = -1;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess) goto done;
    if (SecCodeCheckValidity(self, kSecCSDefaultFlags, NULL) != errSecSuccess) goto done;
#ifdef CALA_KEYCHAIN_TEST_TEAM
    snprintf(out, 64, "%s", CALA_KEYCHAIN_TEST_TEAM); // test builds only: simulate a Developer ID signed helper
    found = 1;
    goto done;
#endif
    if (SecCodeCopyStaticCode(self, kSecCSDefaultFlags, &staticSelf) != errSecSuccess) goto done;
    if (SecCodeCopySigningInformation(staticSelf, kSecCSSigningInformation, &info) != errSecSuccess) goto done;
    CFStringRef team = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
    if (!team) found = 0;
    else if (CFGetTypeID(team) == CFStringGetTypeID() && CFStringGetCString(team, out, 64, kCFStringEncodingUTF8)
             && safe_token(out, "")) found = 1;
done:
    if (info) CFRelease(info);
    if (staticSelf) CFRelease(staticSelf);
    if (self) CFRelease(self);
    return found;
}

static int parent_token(pid_t parent, audit_token_t *token) {
    mach_port_t name = MACH_PORT_NULL;
    if (task_name_for_pid(mach_task_self(), parent, &name) != KERN_SUCCESS) return 0;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    kern_return_t result = task_info(name, TASK_AUDIT_TOKEN, (task_info_t)token, &count);
    mach_port_deallocate(mach_task_self(), name);
    return result == KERN_SUCCESS && audit_token_to_pid(*token) == parent;
}

static int self_token(audit_token_t *token) {
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    return task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)token, &count) == KERN_SUCCESS;
}

// Flavor 17 for `pid`, only if the kernel returns exactly our struct.
static int uniq_info(pid_t pid, struct cala_uniqidentifierinfo *info) {
    memset(info, 0, sizeof *info);
#ifdef CALA_KEYCHAIN_TEST_FAIL_UNIQ
    return 0; // test builds only: as if the kernel refused or changed flavor 17
#endif
    return proc_pidinfo(pid, CALA_PROC_PIDUNIQIDENTIFIERINFO, 0, info, sizeof *info) == (int)sizeof *info;
}

static SecCodeRef guest(CFStringRef key, CFTypeRef value) {
    const void *keys[] = { key };
    const void *values[] = { value };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    if (SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code) != errSecSuccess) code = NULL;
    CFRelease(attributes);
    return code;
}

// 0 = allowed, EXIT_REFUSED = not this bundle's app, EXIT_UNVERIFIED = an anti-race hint was unavailable (Team ID only).
static int caller_check(void) {
    int result = 0;
    SecCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    SecStaticCodeRef staticCode = NULL;
    CFURLRef url = NULL;
    CFStringRef text = NULL;
    CFDataRef audit = NULL;
    CFNumberRef pid = NULL;
    char team[64] = "", ownPath[PATH_MAX], bundleID[256], requirementText[512];
    int hasTeam = 0;
#define REJECT(what) do { result = fail(EXIT_REFUSED, "caller is not Cala: " what, 0); goto done; } while (0)
    // Anti-race hints: skipped without a Team ID, fatal with one.
#define HINT_UNAVAILABLE(what) do { if (hasTeam) { result = fail(EXIT_UNVERIFIED, "cannot verify the caller: " what, 0); \
                                    goto done; } fprintf(stderr, "cala-keychain: skipped (ad-hoc): %s\n", what); } while (0)

    pid_t parent = getppid();
    if (parent <= 1) REJECT("no parent");
    if (!own_bundle(ownPath)) REJECT("this helper is not inside an app bundle");
    hasTeam = own_team(team);
    if (hasTeam < 0) { hasTeam = 0; REJECT("this helper's own signature is not valid"); }
    if (!bundle_identifier(ownPath, bundleID)) REJECT("the app bundle has no usable identifier");
    snprintf(requirementText, sizeof requirementText, hasTeam
             ? "identifier \"%s\" and anchor apple generic and certificate leaf[subject.OU] = \"%s\""
             : "identifier \"%s\"", bundleID, team);

    // The parent's pid version when it forked us, trusted only if the private layout matches our own audit token.
    struct cala_uniqidentifierinfo self, parentInfo;
    audit_token_t own, token, after;
    int32_t forkedBy = 0;
    if (uniq_info(getpid(), &self) && self_token(&own) && self.p_idversion == audit_token_to_pidversion(own)
        && self.p_orig_ppidversion != 0)
        forkedBy = self.p_orig_ppidversion;
    else HINT_UNAVAILABLE("the parent's pid version at fork");
    int haveToken = parent_token(parent, &token);
    if (!haveToken) HINT_UNAVAILABLE("the parent's audit token");
    int32_t version = 0;
    if (haveToken) version = audit_token_to_pidversion(token);
    else if (forkedBy && uniq_info(parent, &parentInfo)) version = parentInfo.p_idversion; // ad-hoc fallback
    if (forkedBy && version && version != forkedBy) REJECT("the parent exec'd after spawning the helper");

    if (haveToken) {
        audit = CFDataCreate(NULL, (const UInt8 *)&token, sizeof token);
        code = guest(kSecGuestAttributeAudit, audit); // bound to this exact incarnation
        if (!code) HINT_UNAVAILABLE("code lookup by audit token");
    }
    if (!code) {
        pid = CFNumberCreate(NULL, kCFNumberIntType, &parent);
        code = guest(kSecGuestAttributePid, pid);
    }
    if (!code) REJECT("cannot locate the parent's code");
    text = CFStringCreateWithCString(NULL, requirementText, kCFStringEncodingUTF8);
    if (!text || SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement) != errSecSuccess)
        REJECT("cannot build the requirement");
    OSStatus validity = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    if (validity != errSecSuccess) {
        fprintf(stderr, "cala-keychain: parent signature check: OSStatus %d\n", (int)validity);
        REJECT("signature or identity");
    }
    char callerPath[PATH_MAX], callerReal[PATH_MAX];
    if (SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &staticCode) != errSecSuccess
        || SecCodeCopyPath(staticCode, kSecCSDefaultFlags, &url) != errSecSuccess
        || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)callerPath, sizeof callerPath)
        || !realpath(callerPath, callerReal))
        REJECT("cannot locate the parent's bundle (replaced or deleted? restart Cala)");
    if (strcmp(callerReal, ownPath) != 0) REJECT("another bundle, or Cala.app was replaced: restart Cala");
    // Still the same parent incarnation after the checks.
    if (getppid() != parent) REJECT("the parent exited");
    if (haveToken) {
        if (!parent_token(parent, &after)) HINT_UNAVAILABLE("re-reading the parent's audit token");
        else if (audit_token_to_pidversion(after) != version) REJECT("the parent exec'd during the check");
    } else if (forkedBy && uniq_info(parent, &parentInfo) && parentInfo.p_idversion != forkedBy) {
        REJECT("the parent exec'd during the check");
    }
done:
#undef REJECT
#undef HINT_UNAVAILABLE
    if (url) CFRelease(url);
    if (staticCode) CFRelease(staticCode);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    if (text) CFRelease(text);
    if (audit) CFRelease(audit);
    if (pid) CFRelease(pid);
    return result;
}
#endif

static CFMutableDictionaryRef base_query(CFStringRef account) {
    CFMutableDictionaryRef query = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, CFSTR(SERVICE));
    CFDictionarySetValue(query, kSecAttrAccount, account);
#ifdef CALA_KEYCHAIN_TEST
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // CALA_KEYCHAIN_TEST_KEYCHAIN points at a temporary keychain, so the login keychain is never touched.
    const char *path = getenv("CALA_KEYCHAIN_TEST_KEYCHAIN");
    SecKeychainRef keychain = NULL;
    if (!path || SecKeychainOpen(path, &keychain) != errSecSuccess) { fputs("test keychain missing\n", stderr); exit(EXIT_BAD_REQUEST); }
    CFArrayRef list = CFArrayCreate(NULL, (const void **)&keychain, 1, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(query, kSecMatchSearchList, list);
    CFDictionarySetValue(query, kSecUseKeychain, keychain);
    CFRelease(list);
    CFRelease(keychain);
#pragma clang diagnostic pop
#endif
    return query;
}

static int get(CFStringRef account) {
    CFMutableDictionaryRef query = base_query(account);
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
#ifdef CALA_KEYCHAIN_TEST
    CFDictionaryRemoveValue(query, kSecUseKeychain);
#endif
    CFTypeRef item = NULL;
    OSStatus status = SecItemCopyMatching(query, &item);
    CFRelease(query);
    if (status != errSecSuccess) return keychain_exit("read failed", status);
    int result = EXIT_FOUND_OK;
    if (!item || CFGetTypeID(item) != CFDataGetTypeID()) result = fail(EXIT_KEYCHAIN, "unexpected item", status);
    else {
        CFDataRef data = item;
        size_t length = (size_t)CFDataGetLength(data);
        if (fwrite(CFDataGetBytePtr(data), 1, length, stdout) != length || fflush(stdout) != 0)
            result = fail(EXIT_KEYCHAIN, "could not write the password", 0);
    }
    if (item) CFRelease(item);
    return result;
}

static int set(CFStringRef account, const UInt8 *password, CFIndex length) {
    CFDataRef data = CFDataCreate(NULL, password, length);
    CFMutableDictionaryRef item = base_query(account);
    CFDictionarySetValue(item, kSecValueData, data);
#ifdef CALA_KEYCHAIN_TEST
    CFDictionaryRemoveValue(item, kSecMatchSearchList);
#endif
    OSStatus status = SecItemAdd(item, NULL);
    CFRelease(item);
    if (status == errSecDuplicateItem) {
        CFMutableDictionaryRef query = base_query(account);
#ifdef CALA_KEYCHAIN_TEST
        CFDictionaryRemoveValue(query, kSecUseKeychain);
#endif
        const void *keys[] = { kSecValueData };
        const void *values[] = { data };
        CFDictionaryRef update = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
        status = SecItemUpdate(query, update);
        CFRelease(update);
        CFRelease(query);
        CFRelease(data);
        return status == errSecSuccess ? EXIT_FOUND_OK : keychain_exit("update failed", status);
    }
    CFRelease(data);
    return status == errSecSuccess ? EXIT_FOUND_OK : keychain_exit("add failed", status);
}

static int delete(CFStringRef account) {
    CFMutableDictionaryRef query = base_query(account);
#ifdef CALA_KEYCHAIN_TEST
    CFDictionaryRemoveValue(query, kSecUseKeychain);
#endif
    OSStatus status = SecItemDelete(query);
    CFRelease(query);
    return status == errSecSuccess ? EXIT_FOUND_OK : keychain_exit("delete failed", status);
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1) return fail(EXIT_BAD_REQUEST, "takes no arguments; the request comes on stdin", 0);
#ifndef CALA_KEYCHAIN_TEST
#ifdef CALA_KEYCHAIN_TEST_DELAY_MS
    usleep(CALA_KEYCHAIN_TEST_DELAY_MS * 1000); // test builds only: lets a racing parent exec() before the check
#endif
    int check = caller_check();
    if (check != 0) return check;
#ifdef CALA_KEYCHAIN_CALLER_PROBE
    return EXIT_FOUND_OK; // test builds only: checks the caller, never touches the Keychain
#endif
#endif
    static UInt8 request[MAX_REQUEST + 1];
    size_t length = 0, n;
    while ((n = fread(request + length, 1, sizeof request - length, stdin)) > 0) {
        length += n;
        if (length > MAX_REQUEST) return fail(EXIT_BAD_REQUEST, "request too large", 0);
    }
    if (ferror(stdin)) return fail(EXIT_BAD_REQUEST, "could not read the request", 0);

    UInt8 *end = request + length;
    UInt8 *commandEnd = memchr(request, '\n', length);
    if (!commandEnd) return fail(EXIT_BAD_REQUEST, "missing command", 0);
    UInt8 *id = commandEnd + 1;
    UInt8 *idEnd = memchr(id, '\n', (size_t)(end - id));
    if (!idEnd) return fail(EXIT_BAD_REQUEST, "missing account id", 0);
    size_t commandLength = (size_t)(commandEnd - request), idLength = (size_t)(idEnd - id);
    if (idLength == 0 || idLength > MAX_ID || memchr(id, 0, idLength)) return fail(EXIT_BAD_REQUEST, "bad account id", 0);
    UInt8 *rest = idEnd + 1;
    CFIndex restLength = (CFIndex)(end - rest);

    CFStringRef account = CFStringCreateWithBytes(NULL, id, (CFIndex)idLength, kCFStringEncodingUTF8, false);
    if (!account) return fail(EXIT_BAD_REQUEST, "account id is not UTF-8", 0);
    int result;
    #define IS(word) (commandLength == sizeof word - 1 && memcmp(request, word, commandLength) == 0)
    if (IS("get") && restLength == 0) result = get(account);
    else if (IS("set")) result = set(account, rest, restLength);
    else if (IS("delete") && restLength == 0) result = delete(account);
    else result = fail(EXIT_BAD_REQUEST, "unknown command", 0);
    CFRelease(account);
    memset(request, 0, sizeof request);
    return result;
}
