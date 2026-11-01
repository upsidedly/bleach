#include "BleachFS.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/param.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <copyfile.h>
#include <sys/clonefile.h>

static void metadata(const struct stat *s, BLStat *out) {
    memset(out, 0, sizeof(*out));
    out->device = s->st_dev; out->inode = s->st_ino; out->links = s->st_nlink;
    out->size = s->st_size; out->allocated = s->st_blocks * 512;
    out->mode = s->st_mode; out->owner = s->st_uid; out->flags = s->st_flags;
    out->modified_sec = s->st_mtimespec.tv_sec; out->modified_nsec = s->st_mtimespec.tv_nsec;
    out->changed_sec = s->st_ctimespec.tv_sec; out->changed_nsec = s->st_ctimespec.tv_nsec;
    out->type = S_ISREG(s->st_mode) ? 1 : S_ISDIR(s->st_mode) ? 2 : S_ISLNK(s->st_mode) ? 3 : 4;
#ifdef SF_DATALESS
    out->dataless = (s->st_flags & SF_DATALESS) != 0;
#endif
}

int bl_read_stat(const char *path, BLStat *out) {
    struct stat s;
    if (lstat(path, &s) < 0) return errno;
    metadata(&s, out); return 0;
}

int bl_stat_fd(int fd, BLStat *out) {
    struct stat s;
    if (fstat(fd, &s) < 0) return errno;
    metadata(&s, out); return 0;
}

static int sorted(const FTSENT **a, const FTSENT **b) { return strcmp((*a)->fts_name, (*b)->fts_name); }

int bl_walk(const char *root, BLVisitor visitor, void *context) {
    char *path = strdup(root);
    if (!path) return ENOMEM;
    char *paths[] = {path, NULL};
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, sorted);
    if (!tree) { int e = errno; free(path); return e; }
    int result = 0;
    FTSENT *entry;
    while (1) {
        errno = 0;
        entry = fts_read(tree);
        if (!entry) { if (errno) result = errno; break; }
        if (entry->fts_info == FTS_DP || entry->fts_info == FTS_DOT) continue;
        if (entry->fts_level > 256) { result = ELOOP; break; }
        BLStat s = {0};
        int error = 0;
        if (entry->fts_info == FTS_ERR || entry->fts_info == FTS_DNR || entry->fts_info == FTS_NS) {
            error = entry->fts_errno ? entry->fts_errno : EIO;
        } else {
            metadata(entry->fts_statp, &s);
            bl_measure_storage(entry->fts_path, &s, &s.storage);
        }
        int action = visitor(entry->fts_path, &s, error, context);
        if (action == 1) { result = ECANCELED; break; }
        if (action == 2 && entry->fts_info == FTS_D) fts_set(tree, entry, FTS_SKIP);
    }
    fts_close(tree); free(path); return result;
}

/* Every ancestor is opened relative to its already-open parent. A linked
   component cannot redirect a later open/rename/unlink to another tree. */
int bl_open_directory(const char *path) {
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    char *copy = strdup(path);
    if (!copy) { errno = ENOMEM; return -1; }
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) { free(copy); return -1; }
    char *state = NULL;
    for (char *part = strtok_r(copy, "/", &state); part; part = strtok_r(NULL, "/", &state)) {
        if (strcmp(part, ".") == 0 || strcmp(part, "..") == 0) {
            close(fd); free(copy); errno = EINVAL; return -1;
        }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) { int e = errno; close(fd); free(copy); errno = e; return -1; }
        close(fd); fd = next;
    }
    free(copy); return fd;
}

static int parent(const char *path, char **name) {
    if (!path || path[0] != '/' || strlen(path) >= MAXPATHLEN) { errno = EINVAL; return -1; }
    char *copy = strdup(path);
    if (!copy) { errno = ENOMEM; return -1; }
    char *slash = strrchr(copy, '/');
    if (!slash || !slash[1]) { free(copy); errno = EINVAL; return -1; }
    *name = strdup(slash + 1);
    if (!*name) { free(copy); errno = ENOMEM; return -1; }
    if (strcmp(*name, ".") == 0 || strcmp(*name, "..") == 0) {
        free(*name); free(copy); errno = EINVAL; return -1;
    }
    if (slash == copy) slash[1] = '\0'; else *slash = '\0';
    int fd = bl_open_directory(copy);
    int e = errno; free(copy); errno = e;
    if (fd < 0) { free(*name); *name = NULL; }
    return fd;
}

int bl_open_regular(const char *path, uint64_t device, uint64_t inode) {
    char *name = NULL;
    int dir = parent(path, &name);
    if (dir < 0) return -1;
    int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    int e = errno; close(dir); free(name);
    if (fd < 0) { errno = e; return -1; }
    struct stat s;
    if (fstat(fd, &s) < 0) { e = errno; close(fd); errno = e; return -1; }
    if (!S_ISREG(s.st_mode) || (uint64_t)s.st_dev != device || s.st_ino != inode) {
        close(fd); errno = ESTALE; return -1;
    }
    return fd;
}

static int unchanged_regular(int fd, const BLStat *expected) {
    BLStat actual;
    if (bl_stat_fd(fd, &actual)) return 0;
    return actual.device == expected->device && actual.inode == expected->inode &&
        actual.type == 1 && actual.links == 1 && actual.owner == getuid() && !actual.dataless &&
        actual.flags == 0 && actual.size == expected->size && actual.mode == expected->mode &&
        actual.modified_sec == expected->modified_sec && actual.modified_nsec == expected->modified_nsec &&
        actual.changed_sec == expected->changed_sec && actual.changed_nsec == expected->changed_nsec;
}

/* Destination is exclusive and every parent is opened without following links.
   On any failure the recovery original remains; never unlink user paths here. */
int bl_clone_copy(const char *keeper, const BLStat *keeper_stat, const char *metadata_source, const BLStat *metadata_stat, const char *destination) {
    int source = bl_open_regular(keeper, keeper_stat->device, keeper_stat->inode);
    if (source < 0) return errno;
    int original = bl_open_regular(metadata_source, metadata_stat->device, metadata_stat->inode);
    if (original < 0) { int e = errno; close(source); return e; }
    char *name = NULL;
    int directory = parent(destination, &name);
    int result = directory < 0 ? errno : 0;
    if (!result && (!unchanged_regular(source, keeper_stat) || !unchanged_regular(original, metadata_stat))) result = ESTALE;
    if (!result && fclonefileat(source, directory, name, 0) < 0) result = errno;
    int replacement = -1;
    if (!result) {
        replacement = openat(directory, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
        if (replacement < 0) result = errno;
    }
    if (!result && fcopyfile(original, replacement, NULL, COPYFILE_METADATA) < 0) result = errno;
    if (!result && (!unchanged_regular(source, keeper_stat) || !unchanged_regular(original, metadata_stat))) result = ESTALE;
    if (!result && fsync(replacement) < 0) result = errno;
    if (!result && fsync(directory) < 0 && errno != EINVAL) result = errno;
    if (replacement >= 0) close(replacement);
    if (directory >= 0) close(directory);
    free(name); close(original); close(source);
    return result;
}

int bl_make_directories(const char *path) {
    if (!path || path[0] != '/') return EINVAL;
    char *copy = strdup(path);
    if (!copy) return ENOMEM;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) { int e = errno; free(copy); return e; }
    int result = 0;
    char *state = NULL;
    for (char *part = strtok_r(copy, "/", &state); part; part = strtok_r(NULL, "/", &state)) {
        if (strcmp(part, ".") == 0 || strcmp(part, "..") == 0) { result = EINVAL; break; }
        if (mkdirat(fd, part, 0700) < 0 && errno != EEXIST) { result = errno; break; }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) { result = errno; break; }
        close(fd); fd = next;
    }
    close(fd); free(copy); return result;
}

int bl_atomic_write(const char *directory, const char *name, const void *data, size_t size) {
    if (!name || strchr(name, '/') || name[0] == '.' || !*name) return EINVAL;
    int dir = bl_open_directory(directory);
    if (dir < 0) return errno;
    char temporary[96];
    snprintf(temporary, sizeof(temporary), ".pending-%d-%08x", getpid(), arc4random());
    int fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { int e = errno; close(dir); return e; }
    const unsigned char *cursor = data;
    size_t left = size;
    int result = 0;
    while (left) {
        ssize_t n = write(fd, cursor, left);
        if (n < 0) { if (errno == EINTR) continue; result = errno; break; }
        if (n == 0) { result = EIO; break; }
        cursor += n; left -= (size_t)n;
    }
    if (!result && fsync(fd) < 0) result = errno;
    close(fd);
    if (!result && renameat(dir, temporary, dir, name) < 0) result = errno;
    if (!result && fsync(dir) < 0 && errno != EINVAL) result = errno;
    if (result) unlinkat(dir, temporary, 0);
    close(dir); return result;
}

int bl_move_exclusive(const char *source, const char *destination, uint64_t device, uint64_t inode) {
    char *src = NULL, *dst = NULL;
    int from = parent(source, &src);
    if (from < 0) return errno;
    int to = parent(destination, &dst);
    if (to < 0) { int e = errno; close(from); free(src); return e; }
    int result = 0;
    struct stat s;
    if (fstatat(from, src, &s, AT_SYMLINK_NOFOLLOW) < 0) result = errno;
    else if ((uint64_t)s.st_dev != device || s.st_ino != inode || S_ISLNK(s.st_mode)) result = ESTALE;
    else if (renameatx_np(from, src, to, dst, RENAME_EXCL) < 0) result = errno;
    else {
        /* Rename cannot atomically compare an inode. Verify the moved object;
           a race remains recoverable and is never followed by deletion. */
        struct stat moved;
        if (fstatat(to, dst, &moved, AT_SYMLINK_NOFOLLOW) < 0) result = errno;
        else if ((uint64_t)moved.st_dev != device || moved.st_ino != inode) {
            renameatx_np(to, dst, from, src, RENAME_EXCL);
            result = ESTALE;
        }
        if (!result) {
            if (fsync(from) < 0 && errno != EINVAL) result = errno;
            if (fsync(to) < 0 && errno != EINVAL) result = errno;
        }
    }
    close(from); close(to); free(src); free(dst); return result;
}

static int erase_at(int dir, const char *name, dev_t volume, unsigned depth) {
    if (depth > 256) return ELOOP;
    struct stat s;
    if (fstatat(dir, name, &s, AT_SYMLINK_NOFOLLOW) < 0) return errno;
    if (s.st_dev != volume) return EXDEV;
    if (!S_ISDIR(s.st_mode)) return unlinkat(dir, name, 0) < 0 ? errno : 0;
    int fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno;
    struct stat opened;
    if (fstat(fd, &opened) < 0 || opened.st_ino != s.st_ino || opened.st_dev != s.st_dev) {
        close(fd); return ESTALE;
    }
    DIR *stream = fdopendir(fd);
    if (!stream) { int e = errno; close(fd); return e; }
    int result = 0;
    while (1) {
        errno = 0;
        struct dirent *entry = readdir(stream);
        if (!entry) { if (errno) result = errno; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        result = erase_at(fd, entry->d_name, volume, depth + 1);
        if (result) break;
    }
    closedir(stream);
    if (!result && unlinkat(dir, name, AT_REMOVEDIR) < 0) result = errno;
    return result;
}

int bl_erase(const char *path, uint64_t device, uint64_t inode) {
    char *name = NULL;
    int dir = parent(path, &name);
    if (dir < 0) return errno;
    struct stat s;
    int result = 0;
    if (fstatat(dir, name, &s, AT_SYMLINK_NOFOLLOW) < 0) result = errno;
    else if ((uint64_t)s.st_dev != device || s.st_ino != inode || S_ISLNK(s.st_mode)) result = ESTALE;
    else result = erase_at(dir, name, s.st_dev, 0);
    if (!result && fsync(dir) < 0 && errno != EINVAL) result = errno;
    free(name); close(dir); return result;
}

int bl_acquire_lock(const char *path) {
    char *name = NULL;
    int dir = parent(path, &name);
    if (dir < 0) return -1;
    int fd = openat(dir, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    int e = errno; close(dir); free(name);
    if (fd < 0) { errno = e; return -1; }
    struct stat s;
    if (fstat(fd, &s) < 0 || !S_ISREG(s.st_mode) || s.st_uid != getuid() || (s.st_mode & 0077)) {
        close(fd); errno = EPERM; return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) { e = errno; close(fd); errno = e; return -1; }
    return fd;
}

void bl_close(int descriptor) { if (descriptor >= 0) close(descriptor); }
int bl_last_error(void) { return errno; }
