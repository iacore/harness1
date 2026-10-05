// The single translation unit `build.zig` feeds to translate-c, so the library
// does not depend on `@cImport` (removed in Zig 0.17).
#include <curl/curl.h>