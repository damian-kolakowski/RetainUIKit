#include "RetainHook.h"
#include "fishhook.h"
#include <objc/objc.h>
#include <stdatomic.h>
#include <pthread.h>

// ---------------------------------------------------------------------------
// fishhook patches the GOT of EVERY loaded image at runtime — including the
// main executable itself.  This is the key difference from DYLD_INTERPOSE,
// which exempts the interposing image's own symbol references (causing the
// main exe's Swift/ObjC ARC calls to be completely invisible to the hook).
//
// Four symbols are hooked:
//   objc_retain / objc_release  — ObjC ARC (NSObject subclasses)
//   swift_retain / swift_release — Swift ARC (pure Swift classes)
//
// Each replacement calls through its stored original function pointer, so
// there is no recursion even though the main exe's GOT entries are patched.
// ---------------------------------------------------------------------------

// Originals — populated by fishhook inside RetainHookInstall().
static id   (*orig_objc_retain)(id)        = NULL;
static void (*orig_objc_release)(id)       = NULL;
static void *(*orig_swift_retain)(void *)  = NULL;
static void  (*orig_swift_release)(void *) = NULL;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Fired on every objc_retain / swift_retain.
static _Atomic(RetainCallback) active_retain_cb  = NULL;

/// Fired on every retain AND release (ObjC and Swift).
static _Atomic(RetainCallback) active_observe_cb = NULL;

/// Per-thread reentrancy guard — the callback may itself retain objects
/// (e.g. appending to an array).  Without this the hook would recurse.
static pthread_key_t reentrance_key;

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

static inline void fire(RetainCallback cb, const void *ptr) {
    if (!cb || !ptr) return;
    if (pthread_getspecific(reentrance_key)) return;
    pthread_setspecific(reentrance_key, (void *)1);
    cb(ptr);
    pthread_setspecific(reentrance_key, NULL);
}

// ---------------------------------------------------------------------------
// Replacements
// ---------------------------------------------------------------------------

static id my_objc_retain(id obj) {
    fire(atomic_load_explicit(&active_retain_cb,  memory_order_relaxed), (const void *)obj);
    fire(atomic_load_explicit(&active_observe_cb, memory_order_relaxed), (const void *)obj);
    return orig_objc_retain(obj);       // call stored original, not the symbol
}

static void my_objc_release(id obj) {
    fire(atomic_load_explicit(&active_observe_cb, memory_order_relaxed), (const void *)obj);
    orig_objc_release(obj);
}

static void *my_swift_retain(void *obj) {
    fire(atomic_load_explicit(&active_retain_cb,  memory_order_relaxed), obj);
    fire(atomic_load_explicit(&active_observe_cb, memory_order_relaxed), obj);
    return orig_swift_retain(obj);
}

static void my_swift_release(void *obj) {
    fire(atomic_load_explicit(&active_observe_cb, memory_order_relaxed), obj);
    orig_swift_release(obj);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void RetainHookInstall(void) {
    static atomic_flag done = ATOMIC_FLAG_INIT;
    if (!atomic_flag_test_and_set(&done)) {
        pthread_key_create(&reentrance_key, NULL);

        // fishhook strips the leading '_' when matching Mach-O symbol names,
        // so "swift_retain" matches the exported symbol "_swift_retain".
        struct rebinding r[] = {
            { "objc_retain",   (void *)my_objc_retain,   (void **)&orig_objc_retain   },
            { "objc_release",  (void *)my_objc_release,  (void **)&orig_objc_release  },
            { "swift_retain",  (void *)my_swift_retain,  (void **)&orig_swift_retain  },
            { "swift_release", (void *)my_swift_release, (void **)&orig_swift_release },
        };
        rebind_symbols(r, 4);
    }
}

void RetainHookBegin(RetainCallback cb) {
    atomic_store_explicit(&active_retain_cb, cb, memory_order_relaxed);
}

void RetainHookEnd(void) {
    atomic_store_explicit(&active_retain_cb, NULL, memory_order_relaxed);
}

void ObserveHookBegin(RetainCallback cb) {
    atomic_store_explicit(&active_observe_cb, cb, memory_order_relaxed);
}

void ObserveHookEnd(void) {
    atomic_store_explicit(&active_observe_cb, NULL, memory_order_relaxed);
}
