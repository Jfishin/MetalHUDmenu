#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

int main(int argc, char **argv) {
    const char *library = getenv("PROBE_DLOPEN");
    if (library && !dlopen(library, RTLD_NOW | RTLD_LOCAL)) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 90;
    }
    unsigned count = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (path && strstr(path, "/libMHUDStats.dylib")) count++;
    }
    printf("loaded=%u\n", count);
    const char *keys[] = {"DYLD_INSERT_LIBRARIES", "STEAM_DYLD_INSERT_LIBRARIES"};
    for (unsigned i = 0; i < 2; i++) printf("%s=%s\n", keys[i], getenv(keys[i]) ?: "");
    for (int i = 1; i < argc; i++) printf("arg=%s\n", argv[i]);
    return getenv("PROBE_EXIT") ? atoi(getenv("PROBE_EXIT")) : 0;
}
