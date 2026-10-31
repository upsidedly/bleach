#include "BleachFS.h"
#include <sys/stat.h>
#include <errno.h>
#include <fts.h>
#include <stdlib.h>
#include <string.h>

/* The read-only analyzer aggregates while walking. Swift receives only the
   immediate children and bounded largest-file list, not one object per file. */
typedef struct { uint64_t device, inode; int occupied; } Identity;
typedef struct { Identity *slots; size_t capacity, used; } IdentitySet;

static uint64_t mix(uint64_t n) {
    n ^= n >> 30; n *= UINT64_C(0xbf58476d1ce4e5b9);
    n ^= n >> 27; n *= UINT64_C(0x94d049bb133111eb);
    return n ^ (n >> 31);
}
static int insert(IdentitySet *set, uint64_t device, uint64_t inode) {
    if (!set->capacity || (set->used + 1) * 2 >= set->capacity) {
        size_t capacity = set->capacity ? set->capacity * 2 : 64;
        Identity *slots = calloc(capacity, sizeof(*slots));
        if (!slots) return -1;
        for (size_t i = 0; i < set->capacity; i++) {
            if (!set->slots[i].occupied) continue;
            size_t at = mix(set->slots[i].inode ^ mix(set->slots[i].device)) & (capacity - 1);
            while (slots[at].occupied) at = (at + 1) & (capacity - 1);
            slots[at] = set->slots[i];
        }
        free(set->slots); set->slots = slots; set->capacity = capacity;
    }
    size_t at = mix(inode ^ mix(device)) & (set->capacity - 1);
    while (set->slots[at].occupied) {
        if (set->slots[at].device == device && set->slots[at].inode == inode) return 0;
        at = (at + 1) & (set->capacity - 1);
    }
    set->slots[at] = (Identity){device, inode, 1}; set->used++; return 1;
}

static int compare_entries(const FTSENT **a, const FTSENT **b) { return strcmp((*a)->fts_name, (*b)->fts_name); }

static int issue(BLAnalysis *out, const char *path, int code) {
    if (out->issue_count >= 1000) return 0;
    BLAnalysisIssue *resized = realloc(out->issues, sizeof(*resized) * (out->issue_count + 1));
    if (!resized) return ENOMEM;
    out->issues = resized;
    char *copy = strdup(path);
    if (!copy) return ENOMEM;
    out->issues[out->issue_count++] = (BLAnalysisIssue){copy, code}; return 0;
}

/* Rank private storage first, with attributed allocation as a tie breaker. */
static int worse(const BLAnalysisEntry *a, const BLAnalysisEntry *b) {
    if (a->storage.private_bytes != b->storage.private_bytes)
        return a->storage.private_bytes < b->storage.private_bytes;
    return a->allocated < b->allocated || (a->allocated == b->allocated && strcmp(a->path, b->path) > 0);
}
static void exchange(BLAnalysisEntry *a, BLAnalysisEntry *b) { BLAnalysisEntry copy = *a; *a = *b; *b = copy; }
static int largest(BLAnalysis *out, size_t limit, const char *path, const struct stat *s, const BLStorage *storage) {
    if (!limit) return 0;
    int64_t allocation = s->st_blocks * 512;
    BLAnalysisEntry value = {.path = (char *)path, .logical = s->st_size,
        .allocated = allocation, .files = 1, .storage = *storage};
    if (out->largest_count == limit && !worse(&out->largest[0], &value)) return 0;
    char *copy = strdup(path);
    if (!copy) return ENOMEM;
    value.path = copy;
    if (out->largest_count < limit) {
        size_t at = out->largest_count++;
        out->largest[at] = value;
        while (at) {
            size_t parent = (at - 1) / 2;
            if (!worse(&out->largest[at], &out->largest[parent])) break;
            exchange(&out->largest[at], &out->largest[parent]); at = parent;
        }
    } else {
        free(out->largest[0].path); out->largest[0] = value;
        size_t at = 0;
        while (at * 2 + 1 < out->largest_count) {
            size_t child = at * 2 + 1;
            if (child + 1 < out->largest_count && worse(&out->largest[child + 1], &out->largest[child])) child++;
            if (!worse(&out->largest[child], &out->largest[at])) break;
            exchange(&out->largest[child], &out->largest[at]); at = child;
        }
    }
    return 0;
}

void bl_free_analysis(BLAnalysis *out) {
    if (!out) return;
    for (size_t i = 0; i < out->entry_count; i++) { free(out->entries[i]->path); free(out->entries[i]); }
    free(out->entries);
    for (size_t i = 0; i < out->largest_count; i++) free(out->largest[i].path);
    free(out->largest);
    for (size_t i = 0; i < out->issue_count; i++) free(out->issues[i].path);
    free(out->issues); memset(out, 0, sizeof(*out));
}

int bl_analyze(const char *root, size_t limit, BLCancellation cancelled, void *context, BLAnalysis *out) {
    memset(out, 0, sizeof(*out));
    if (limit > 10000) return EINVAL;
    struct stat initial;
    if (lstat(root, &initial) < 0) return errno;
    if (S_ISLNK(initial.st_mode)) return ELOOP;
    char *copy = strdup(root);
    if (!copy) return ENOMEM;
    if (limit) {
        out->largest = calloc(limit, sizeof(*out->largest));
        if (!out->largest) { free(copy); return ENOMEM; }
    }
    char *paths[] = {copy, NULL};
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, compare_entries);
    if (!tree) { int e = errno; free(copy); return e; }
    IdentitySet identities = {0};
    int result = 0;
    FTSENT *entry;
    while (1) {
        if (cancelled && cancelled(context)) { result = ECANCELED; break; }
        errno = 0;
        entry = fts_read(tree);
        if (!entry) { if (errno) result = errno; break; }
        if (entry->fts_info == FTS_DP || entry->fts_info == FTS_DOT) continue;
        if (entry->fts_info == FTS_ERR || entry->fts_info == FTS_NS || entry->fts_info == FTS_DNR) {
            result = issue(out, entry->fts_path, entry->fts_errno ? entry->fts_errno : EIO);
            if (result) break;
            continue;
        }
        if (entry->fts_level > 256) { result = ELOOP; break; }
        const struct stat *s = entry->fts_statp;
        if (s->st_dev != initial.st_dev) {
            result = issue(out, entry->fts_path, EXDEV);
            if (entry->fts_info == FTS_D) fts_set(tree, entry, FTS_SKIP);
            if (result) break;
            continue;
        }
        BLAnalysisEntry *top = NULL;
        if (entry->fts_level == 1) {
            top = calloc(1, sizeof(*top));
            if (!top) { result = ENOMEM; break; }
            top->path = strdup(entry->fts_path); top->directory = S_ISDIR(s->st_mode);
            top->symbolic_link = S_ISLNK(s->st_mode);
            if (!top->path) { free(top); result = ENOMEM; break; }
            BLAnalysisEntry **entries = realloc(out->entries, sizeof(*entries) * (out->entry_count + 1));
            if (!entries) { free(top->path); free(top); result = ENOMEM; break; }
            out->entries = entries; out->entries[out->entry_count++] = top;
        } else if (entry->fts_level > 1) top = entry->fts_parent->fts_pointer;
        entry->fts_pointer = top;
        out->nodes++;
        int unique = 1;
        if (!S_ISDIR(s->st_mode) && s->st_nlink > 1) {
            unique = insert(&identities, s->st_dev, s->st_ino);
            if (unique < 0) { result = ENOMEM; break; }
        }
        if (unique) {
            int64_t allocation = s->st_blocks * 512;
            BLStat metadata = {.device = (uint64_t)s->st_dev, .inode = s->st_ino,
                .links = s->st_nlink, .allocated = allocation,
                .type = S_ISREG(s->st_mode) ? 1 : S_ISDIR(s->st_mode) ? 2 : S_ISLNK(s->st_mode) ? 3 : 4};
#ifdef SF_DATALESS
            metadata.dataless = (s->st_flags & SF_DATALESS) != 0;
#endif
            BLStorage storage;
            bl_measure_storage(entry->fts_path, &metadata, &storage);
            bl_add_storage(&out->storage, &storage);
            if (top) bl_add_storage(&top->storage, &storage);
            out->allocated += allocation;
            if (top) top->allocated += allocation;
            if (S_ISREG(s->st_mode)) {
                out->files++; out->logical += s->st_size;
                if (top) { top->files++; top->logical += s->st_size; }
                result = largest(out, limit, entry->fts_path, s, &storage);
                if (result) break;
            }
        }
#ifdef SF_DATALESS
        if (S_ISDIR(s->st_mode) && (s->st_flags & SF_DATALESS)) {
            fts_set(tree, entry, FTS_SKIP);
            result = issue(out, entry->fts_path, ENODATA);
            if (result) break;
        }
#endif
    }
    fts_close(tree); free(copy); free(identities.slots);
    if (!result) {
        struct stat after;
        if (lstat(root, &after) < 0) result = errno;
        else if (after.st_dev != initial.st_dev || after.st_ino != initial.st_ino ||
                 after.st_mtimespec.tv_sec != initial.st_mtimespec.tv_sec || after.st_mtimespec.tv_nsec != initial.st_mtimespec.tv_nsec ||
                 after.st_ctimespec.tv_sec != initial.st_ctimespec.tv_sec || after.st_ctimespec.tv_nsec != initial.st_ctimespec.tv_nsec) {
            result = issue(out, root, ESTALE);
        }
    }
    return result;
}
