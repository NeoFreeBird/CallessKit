#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// CallessKit
// -----------------------------------------------------------------------------
// Stops CallKit provider reset loops in any app.
//
// An app that supports VoIP calls creates a CXProvider at launch; it is its connection to
// callservicesd. When callservicesd won't accept the app as a call provider (an app run
// inside an app extension, such as a LiveContainer Multitask LiveProcess),
// it resets the provider right after it is created. Apps recover from a reset by creating a
// new provider, which is reset again: X did this ~500 times a second, on the main thread,
// each round with a synchronous AudioSession XPC call, costing CPU and frame rate and
// stalling the UI.
//
// Fix: every app hands CallKit its delegate through -[CXProvider setDelegate:queue:], so
// that is hooked to guard the delegate class's providerDidReset:, and every reset is
// swallowed: the app keeps its reset provider and doesn't build another. CallKit can't
// work from an extension anyway.
//
// Only active in a LiveProcess (Multitask). A normal launch runs in the container app's
// own process, where CallKit accepts the provider, and is left untouched.
// CallKit isn't linked: the hook is installed when the app itself loads CallKit.

static SEL resetSelector;

static os_unfair_lock guardLock = OS_UNFAIR_LOCK_INIT;
// Delegate classes already guarded, each with the providerDidReset: it replaced (kept only
// for reference: in a LiveProcess the original is never called).
static CFMutableDictionaryRef originalResetIMPs;
static uint64_t swallowedResets;

static bool classDefinesMethod(Class cls, SEL selector) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    bool found = false;
    for (unsigned i = 0; i < count && !found; i++) {
        found = method_getName(methods[i]) == selector;
    }
    free(methods);
    return found;
}

static void guardedProviderDidReset(id self, __unused SEL _cmd, __unused id provider) {
    os_unfair_lock_lock(&guardLock);
    uint64_t count = ++swallowedResets;
    os_unfair_lock_unlock(&guardLock);
    // Logged on the first few and then sparsely, so a loop that survives shows up.
    if (count <= 3 || count % 1000 == 0) {
        NSLog(@"[CallessKit] ignored CallKit provider reset #%llu (%@)", count, NSStringFromClass(object_getClass(self)));
    }
}

static void guardDelegateClass(Class cls) {
    if (!cls) {
        return;
    }
    Method method = class_getInstanceMethod(cls, resetSelector);
    if (!method) {
        return; // providerDidReset: is required, but don't assume
    }
    os_unfair_lock_lock(&guardLock);
    if (CFDictionaryContainsKey(originalResetIMPs, (__bridge const void *)cls) ||
        method_getImplementation(method) == (IMP)guardedProviderDidReset) {
        os_unfair_lock_unlock(&guardLock);
        return;
    }
    IMP original;
    if (classDefinesMethod(cls, resetSelector)) {
        original = method_setImplementation(method, (IMP)guardedProviderDidReset);
    } else {
        // Inherited: override it on this class, leaving the superclass untouched.
        original = method_getImplementation(method);
        class_addMethod(cls, resetSelector, (IMP)guardedProviderDidReset, method_getTypeEncoding(method));
    }
    CFDictionarySetValue(originalResetIMPs, (__bridge const void *)cls, (const void *)original);
    os_unfair_lock_unlock(&guardLock);
    NSLog(@"[CallessKit] guarding provider resets of %@", NSStringFromClass(cls));
}

// MARK: - -[CXProvider setDelegate:queue:]
//
// Hooked on CXProvider and on any provider subclass that overrides it (iOS hands out
// CXXPCProvider instances); guarding is idempotent if both run through a super call.

typedef void (*SetDelegateIMP)(id, SEL, id, id);
static SetDelegateIMP originalSetDelegate;
static SetDelegateIMP originalSubclassSetDelegate;

static void hookSetDelegate(id self, SEL _cmd, id delegate, id queue) {
    originalSetDelegate(self, _cmd, delegate, queue);
    if (delegate) {
        guardDelegateClass(object_getClass(delegate));
    }
}

static void hookSubclassSetDelegate(id self, SEL _cmd, id delegate, id queue) {
    originalSubclassSetDelegate(self, _cmd, delegate, queue);
    if (delegate) {
        guardDelegateClass(object_getClass(delegate));
    }
}

static bool hookDefinedMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !classDefinesMethod(cls, selector)) {
        return false;
    }
    *original = method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
    return true;
}

static void installProviderHooks(void) {
    static bool installed;
    if (installed) {
        return;
    }
    Class provider = objc_getClass("CXProvider");
    if (!provider) {
        return;
    }
    installed = true;
    SEL setDelegate = @selector(setDelegate:queue:);
    bool base = hookDefinedMethod(provider, setDelegate, (IMP)hookSetDelegate, (IMP *)&originalSetDelegate);
    bool subclass = hookDefinedMethod(objc_getClass("CXXPCProvider"), setDelegate, (IMP)hookSubclassSetDelegate,
                                      (IMP *)&originalSubclassSetDelegate);
    NSLog(@"[CallessKit] CallKit loaded, watching provider delegates (CXProvider %s, CXXPCProvider %s)",
          base ? "hooked" : "no own setDelegate:queue:", subclass ? "hooked" : "no override");
}

static void onImageAdded(const struct mach_header *header, __unused intptr_t slide) {
    Dl_info info;
    if (dladdr(header, &info) && info.dli_fname && strstr(info.dli_fname, "/CallKit.framework/CallKit")) {
        installProviderHooks();
    }
}

%ctor {
    // Only a LiveProcess has this: the app is running inside an app extension.
    if (!getenv("LP_HOME_PATH")) {
        NSLog(@"[CallessKit] normal launch, not active");
        return;
    }
    resetSelector = @selector(providerDidReset:);
    originalResetIMPs = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    NSLog(@"[CallessKit] loaded (LiveProcess): CallKit provider resets will be ignored");
    // Also called for the images already loaded, so the load order doesn't matter.
    _dyld_register_func_for_add_image(onImageAdded);
}
