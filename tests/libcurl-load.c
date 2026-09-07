/* Isolate dependency constructor leaks from Zsh and zcurl. Linux test aid. */
#include <dlfcn.h>
#include <stdio.h>

int main(void)
{
    void *library = dlopen("libcurl.so.4", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    return dlclose(library) != 0;
}
