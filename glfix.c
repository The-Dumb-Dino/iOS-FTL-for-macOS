// glfix.c
//
// Redirects the game's dlsym("gl...") lookups from libGL (desktop OpenGL)
// to OpenGLES (Mac Catalyst).
//
// Why: the game resolves its GL functions at runtime via dlsym. On iOS there is
// only one "glGetString". On macOS the global lookup finds libGL's desktop
// version first, which expects a CGL context and crashes when only an EAGL
// context exists.
//
// Environment variables:
//   GLFIX_DEBUG=1      log GL functions that OpenGLES does not provide
//   GLFIX_MAIN_ONLY=1  redirect only lookups made by the main binary
//                      (experimental, the caller detection is unreliable)

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

// Registers a replacement function with dyld's interposing mechanism.
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

// Possible locations of the Mac Catalyst OpenGLES framework.
static const char *const kGLESPaths[] = {
    "/System/iOSSupport/System/Library/Frameworks/OpenGLES.framework/Versions/A/OpenGLES",
    "/System/iOSSupport/System/Library/Frameworks/OpenGLES.framework/OpenGLES",
};

static void *gles;                 // Handle for the OpenGLES library
static int debug;                  // Set by GLFIX_DEBUG
static int all_callers;            // Cleared by GLFIX_MAIN_ONLY
static const void *main_header;    // Mach-O header of the main binary
static pthread_once_t once = PTHREAD_ONCE_INIT;

// One-time setup: read the environment, find the main binary, load OpenGLES.
static void init(void) {
    debug = getenv("GLFIX_DEBUG") != NULL;
    all_callers = getenv("GLFIX_MAIN_ONLY") == NULL;
    main_header = _dyld_get_image_header(0); // Only used with GLFIX_MAIN_ONLY

    for (unsigned i = 0; i < sizeof(kGLESPaths) / sizeof(kGLESPaths[0]) && !gles; i++)
        gles = dlopen(kGLESPaths[i], RTLD_NOW | RTLD_LOCAL);

    if (debug) fprintf(stderr, "[glfix] OpenGLES handle: %p\n", gles);
}

// True for names like "glClear" (gl followed by an uppercase letter).
static inline int is_gl_name(const char *n) {
    return n && n[0] == 'g' && n[1] == 'l' && n[2] >= 'A' && n[2] <= 'Z';
}

// True if the given address lies inside the main binary.
static int caller_is_main(const void *addr) {
    Dl_info info;
    return dladdr(addr, &info) && info.dli_fbase == main_header;
}

__attribute__((noinline))
static void *my_dlsym(void *handle, const char *name) {
    if (is_gl_name(name)) {
        pthread_once(&once, init);

        if (gles && (all_callers || caller_is_main(__builtin_return_address(0)))) {
            void *p = dlsym(gles, name);
            if (!p && debug)
                fprintf(stderr, "[glfix] %s not found in OpenGLES -> NULL\n", name);
            // Returning NULL is intentional: it lets the game detect that a
            // function is unavailable instead of calling into libGL.
            return p;
        }
    }
    return dlsym(handle, name);
}
DYLD_INTERPOSE(my_dlsym, dlsym)
