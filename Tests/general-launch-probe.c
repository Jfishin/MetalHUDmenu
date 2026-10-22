#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *report = getenv("MHUD_PROBE_REPORT");
    if (!report) return 2;
    FILE *file = fopen(report, "w");
    if (!file) return 3;
    unsigned count = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (path && strstr(path, "/libMHUDStats.dylib")) count++;
    }
    fprintf(file, "loaded=%u\n", count);
    const char *keys[] = {"MTL_HUD_ENABLED", "MTL_HUD_ELEMENTS", "MTL_HUD_SCALE",
        "MTL_HUD_OPACITY", "MTL_HUD_ALIGNMENT", "STEAM_DYLD_INSERT_LIBRARIES"};
    for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
        fprintf(file, "%s=%s\n", keys[i], getenv(keys[i]) ?: "");
    for (int i = 1; i < argc; i++) fprintf(file, "arg=%s\n", argv[i]);
    fclose(file);
    return 0;
}
