#ifndef BLEACH_FS_H
#define BLEACH_FS_H
#include <stdint.h>
#include <stddef.h>

/* Allocation attributed to names is not necessarily private disk usage. These
   disjoint byte buckets sum to attributed allocation after hard-link dedup. */
typedef struct {
    int64_t private_bytes, shared_bytes, hard_linked_bytes, unverified_bytes;
    int64_t shared_files, clone_files, hard_linked_files, symbolic_links;
} BLStorage;

typedef struct {
    uint64_t device, inode, links;
    int64_t size, allocated, modified_sec, modified_nsec, changed_sec, changed_nsec;
    uint32_t mode, owner, flags;
    int type; /* 1 regular, 2 directory, 3 symlink, 4 other */
    int dataless;
    BLStorage storage;
} BLStat;

void bl_measure_storage(const char *path, const BLStat *metadata, BLStorage *out);
void bl_add_storage(BLStorage *total, const BLStorage *item);

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
/* 1 in use, 0 no visible reference, negative errno when inspection is partial. */
int bl_path_in_use(const char *path, int include_cwd);
int bl_clone_copy(const char *keeper, const BLStat *keeper_stat, const char *metadata_source, const BLStat *metadata_stat, const char *destination);

typedef struct {
    char *path;
    int directory;
    int64_t logical, allocated, files;
    BLStorage storage;
    int symbolic_link;
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
    BLStorage storage;
} BLAnalysis;
typedef int (*BLCancellation)(void *context);
int bl_analyze(const char *root, size_t largest_limit, BLCancellation cancelled, void *context, BLAnalysis *out);
void bl_free_analysis(BLAnalysis *result);
#endif
