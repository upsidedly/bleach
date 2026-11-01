#include "BleachFS.h"
#include <errno.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>

static int within(const char *path, const char *root) {
    size_t length = strlen(root);
    return !strncmp(path, root, length) && (!path[length] || path[length] == '/');
}

static int arguments_reference(pid_t pid, const char *path) {
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    const size_t capacity = 1024 * 1024;
    size_t length = capacity;
    char *buffer = malloc(capacity);
    if (!buffer) return -ENOMEM;
    int result = 0;
    if (sysctl(mib, 3, buffer, &length, NULL, 0) < 0) {
        result = (errno == ESRCH || errno == ENOENT || errno == EINVAL) ? 0 : -EACCES;
    } else if (length >= sizeof(int) && length <= capacity) {
        int count;
        memcpy(&count, buffer, sizeof(count));
        char *cursor = buffer + sizeof(count), *end = buffer + length;
        size_t executable = strnlen(cursor, (size_t)(end - cursor));
        cursor += executable;
        while (cursor < end && !*cursor) cursor++;
        /* Only argc arguments are examined. Never inspect or retain env values. */
        for (int index = 0; index < count && cursor < end; index++) {
            size_t size = strnlen(cursor, (size_t)(end - cursor));
            if (size == (size_t)(end - cursor)) break;
            const char *argument = cursor;
            const char *equals = strchr(argument, '=');
            if (argument[0] != '/' && equals) argument = equals + 1;
            if (argument[0] == '/' && within(argument, path)) { result = 1; break; }
            cursor += size + 1;
        }
    }
    volatile unsigned char *wipe = (volatile unsigned char *)buffer;
    for (size_t index = 0; index < capacity; index++) wipe[index] = 0;
    free(buffer);
    return result;
}

/* Read-only census of visible processes owned by this user. Unknown reference
   state fails closed; callers must not describe it as an idle project. */
int bl_path_in_use(const char *path, int include_cwd) {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0 || bytes > 1024 * 1024) return -EIO;
    int capacity = bytes + 4096;
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids) return -ENOMEM;
    bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, capacity);
    if (bytes <= 0 || bytes >= capacity) { free(pids); return -EAGAIN; }
    int result = 0;
    for (int index = 0; index < bytes / (int)sizeof(pid_t) && !result; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) continue;
        struct proc_bsdinfo info;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_uid != getuid()) continue;
        if (include_cwd) {
            struct proc_vnodepathinfo cwd;
            int count = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, sizeof(cwd));
            if (count == sizeof(cwd) && within(cwd.pvi_cdir.vip_path, path)) { result = 1; break; }
            if (count <= 0 && errno != ESRCH && errno != ENOENT) { result = -EACCES; break; }
        }
        /* Our own short-lived scan/hash descriptors are not external use. */
        if (pid == getpid()) continue;
        char executable[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid, executable, sizeof(executable)) > 0 && within(executable, path)) { result = 1; break; }
        result = arguments_reference(pid, path);
        if (result) break;
        errno = 0;
        int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (size <= 0) { if (errno == EACCES || errno == EPERM) result = -EACCES; continue; }
        if (size > 2 * 1024 * 1024) { result = -E2BIG; break; }
        size += 4096;
        struct proc_fdinfo *fds = malloc((size_t)size);
        if (!fds) { result = -ENOMEM; break; }
        int used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, size);
        if (used >= size) result = -EAGAIN;
        else if (used <= 0 && (errno == EACCES || errno == EPERM)) result = -EACCES;
        for (int entry = 0; entry < used / (int)sizeof(*fds) && !result; entry++) {
            if (fds[entry].proc_fdtype != PROX_FDTYPE_VNODE) continue;
            struct vnode_fdinfowithpath vnode;
            int read = proc_pidfdinfo(pid, fds[entry].proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, sizeof(vnode));
            if (read == sizeof(vnode) && within(vnode.pvip.vip_path, path)) result = 1;
            else if (read <= 0 && errno == EACCES) result = -EACCES;
        }
        free(fds);
    }
    free(pids);
    return result;
}
