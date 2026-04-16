// Copyright (c) 2013, Facebook, Inc. All rights reserved.
// BSD License — see fishhook.c for full text.

#ifndef fishhook_h
#define fishhook_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct rebinding {
    const char *name;        // symbol to rebind (e.g. "swift_retain")
    void       *replacement; // pointer to replacement function
    void      **replaced;    // out-param: receives the original function pointer
};

// Walk every loaded image's lazy + non-lazy symbol pointer tables and replace
// each reference to `name` with `replacement`, storing the original in `replaced`.
// Registers for future image loads too.  Returns 0 on success, -1 on alloc failure.
int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

int rebind_symbols_image(void *header,
                         intptr_t slide,
                         struct rebinding rebindings[],
                         size_t rebindings_nel);

#ifdef __cplusplus
}
#endif

#endif /* fishhook_h */
