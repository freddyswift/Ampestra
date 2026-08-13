#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*AmpestraEntryPoint)(void);

static int payload_path(char *destination, size_t capacity) {
    char executable_path[PATH_MAX];
    uint32_t executable_path_size = sizeof(executable_path);

    if (_NSGetExecutablePath(executable_path, &executable_path_size) != 0) {
        return 0;
    }

    char resolved_path[PATH_MAX];
    if (realpath(executable_path, resolved_path) == NULL) {
        return 0;
    }

    char *last_separator = strrchr(resolved_path, '/');
    if (last_separator == NULL) {
        return 0;
    }
    *last_separator = '\0';

    int written = snprintf(
        destination,
        capacity,
        "%s/../Frameworks/libAmpestraDevPayload.dylib",
        resolved_path
    );
    return written > 0 && (size_t)written < capacity;
}

int main(void) {
    char path[PATH_MAX];
    if (!payload_path(path, sizeof(path))) {
        fputs("Ampestra Dev could not locate its app payload.\n", stderr);
        return EXIT_FAILURE;
    }

    void *payload = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (payload == NULL) {
        fprintf(stderr, "Ampestra Dev could not load its app payload: %s\n", dlerror());
        return EXIT_FAILURE;
    }

    dlerror();
    AmpestraEntryPoint entry_point =
        (AmpestraEntryPoint)dlsym(payload, "AmpestraDevMain");
    const char *symbol_error = dlerror();
    if (symbol_error != NULL || entry_point == NULL) {
        fprintf(
            stderr,
            "Ampestra Dev payload is missing its entry point: %s\n",
            symbol_error == NULL ? "unknown error" : symbol_error
        );
        dlclose(payload);
        return EXIT_FAILURE;
    }

    entry_point();
    dlclose(payload);
    return EXIT_SUCCESS;
}
