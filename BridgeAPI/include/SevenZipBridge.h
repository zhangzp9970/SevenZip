#ifndef SEVENZIP_BRIDGE_H
#define SEVENZIP_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define SZB_API __attribute__((visibility("default")))
/* Synchronous C ABI. All strings are UTF-8. Callbacks may run on engine worker
   threads, and pointers passed to callbacks are borrowed for that call only. */
enum { SZB_OK = 0, SZB_WARNING = 1, SZB_ERROR = 2, SZB_CANCELLED = 255 };
enum { SZB_FORMAT_ZIP = 1, SZB_FORMAT_7Z = 7 };
enum { SZB_ENTRY_DIRECTORY = 1, SZB_ENTRY_ENCRYPTED = 2,
       SZB_ENTRY_HAS_SIZE = 4, SZB_ENTRY_HAS_PACKED_SIZE = 8,
       SZB_ENTRY_HAS_MODIFIED = 16 };
typedef struct SZBEntry {
    const char *path;
    uint64_t size;
    uint64_t packed_size;
    int64_t modified_seconds;
    uint32_t flags;
} SZBEntry;
typedef struct SZBCallbacks {
    void *context;
    void (*progress)(void *context, uint64_t completed, uint64_t total);
    int (*is_cancelled)(void *context);
    /* severity: 0 information, 1 warning, 2 error. */
    void (*message)(void *context, int severity, const char *message);
    void (*entry)(void *context, const SZBEntry *entry);
} SZBCallbacks;
SZB_API const char *szb_version(void);
SZB_API int szb_list(const char *archive, const char *password, const SZBCallbacks *callbacks);
/* sources and paths contain count entries, including explicit directories.
   Swift enumerates input trees; paths are safe relative archive paths.
   Output must not exist. The caller publishes the temporary output atomically. */
SZB_API int szb_create(const char *archive, int format, int level,
                       const char *password, const char *const *sources,
                       const char *const *paths, size_t count, const SZBCallbacks *callbacks);
/* Update an existing, single-volume ZIP or 7z into a NEW output file.
   Added paths replace matching entries; directories merge with existing trees.
   Deleted directory paths include their descendants. Unchanged entries retain
   their archive data/properties. The original archive is never modified.
   Output must not exist; on failure it is removed. The caller atomically
   publishes a successful output and retains a recoverable original backup.
   Encrypted archives require their original password. Only SZB_OK is success:
   warnings, unsupported structures and failed integrity checks are errors. */
SZB_API int szb_update(const char *archive, const char *output, int format,
                       const char *password, const char *const *sources,
                       const char *const *paths, size_t count,
                       const char *const *deleted, size_t deleted_count,
                       const SZBCallbacks *callbacks);
/* selected == NULL extracts all; otherwise selected_count must be > 0.
   Selecting a directory includes its descendants. Existing files are renamed.
   Symlink entries and symlink path components are rejected. */
SZB_API int szb_extract(const char *archive, const char *destination,
                        const char *const *selected, size_t selected_count,
                        const char *password, const SZBCallbacks *callbacks);
SZB_API int szb_test(const char *archive, const char *password, const SZBCallbacks *callbacks);
#ifdef __cplusplus
}
#endif
#endif
