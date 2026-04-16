#ifndef RetainHook_h
#define RetainHook_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Fired for every hooked ARC operation.
/// @param obj  Raw object pointer — do NOT retain/release it inside the
///             callback, that would recurse back into the hook.
typedef void (*RetainCallback)(const void *obj);

/// Install both hooks (objc_retain + objc_release).
/// Safe to call multiple times — installs only once.
void RetainHookInstall(void);

// ---------------------------------------------------------------------------
// Retain-only observation  (fires on objc_retain)
// ---------------------------------------------------------------------------

void RetainHookBegin(RetainCallback callback);
void RetainHookEnd(void);

// ---------------------------------------------------------------------------
// Full ARC observation  (fires on objc_retain AND objc_release)
// ---------------------------------------------------------------------------

void ObserveHookBegin(RetainCallback callback);
void ObserveHookEnd(void);

#ifdef __cplusplus
}
#endif

#endif /* RetainHook_h */
