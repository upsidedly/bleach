#ifndef BLEACH_FS_H
#define BLEACH_FS_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint64_t device, inode, links;
    int64_t size, allocated, modified_sec, modified_nsec, changed_sec, changed_nsec;
    uint32_t mode, owner, flags;
    int type; /* 1 regular, 2 directory, 3 symlink, 4 other */
    int dataless;
} BLStat;

/* Return 0 to continue, 1 to cancel, or 2 to skip this directory's descendants. */
typedef int (*BLVisitor)(const char *path, const BLStat *metadata, int error, void *context);
int bl_walk(const char *root, BLVisitor visitor, void *context);
int bl_read_stat(const char *path, BLStat *out);
int bl_open_directory(const char *path);
int bl_open_regular(const char *path, uint64_t device, uint64_t inode);
int bl_stat_fd(int descriptor, BLStat *out);
int bl_make_directories(const char *path);
int bl_atomic_write(const char *directory, const char *name, const void *data, size_t size);
int bl_move_exclusive(const char *source, const char *destination, uint64_t device, uint64_t inode);
int bl_erase(const char *path, uint64_t device, uint64_t inode);
int bl_acquire_lock(const char *path);
void bl_close(int descriptor);
int bl_last_error(void);

typedef struct {
    char *path;
    int directory;
    int64_t logical, allocated, files;
} BLAnalysisEntry;
typedef struct { char *path; int code; } BLAnalysisIssue;
typedef struct {
    BLAnalysisEntry **entries;
    size_t entry_count;
    BLAnalysisEntry *largest;
    size_t largest_count;
    BLAnalysisIssue *issues;
    size_t issue_count;
    int64_t logical, allocated, files, nodes;
} BLAnalysis;
typedef int (*BLCancellation)(void *context);
int bl_analyze(const char *root, size_t largest_limit, BLCancellation cancelled, void *context, BLAnalysis *out);
void bl_free_analysis(BLAnalysis *result);
#endif
