#include "BleachFS.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <mach/mach_time.h>

int bl_process_sample(int32_t pid, BLProcessSample *out) {
    struct proc_bsdinfo identity = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, sizeof(identity)) != sizeof(identity) || identity.pbi_uid != getuid()) return -1;
    struct rusage_info_v2 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) return -1;
    memset(out, 0, sizeof(*out));
    out->pid = pid;
    out->parent_pid = identity.pbi_ppid;
    out->started = usage.ri_proc_start_abstime;
    // libproc returns Mach absolute ticks, including on Apple silicon where
    // one tick is not one nanosecond. Convert before comparing with uptime.
    mach_timebase_info_data_t scale;
    if (mach_timebase_info(&scale) != KERN_SUCCESS || scale.denom == 0) return -1;
    __uint128_t nanos = ((__uint128_t)usage.ri_user_time + usage.ri_system_time) * scale.numer / scale.denom;
    out->cpu_nanoseconds = nanos > UINT64_MAX ? UINT64_MAX : (uint64_t)nanos;
    out->footprint = usage.ri_phys_footprint;
    if (proc_name(pid, out->name, sizeof(out->name)) <= 0) strlcpy(out->name, identity.pbi_name, sizeof(out->name));
    return 0;
}

int bl_process_samples(BLProcessSample *out, size_t capacity) {
    if (!out || capacity == 0 || capacity > 8192) { errno = EINVAL; return -1; }
    pid_t *pids = calloc(capacity, sizeof(pid_t));
    if (!pids) return -1;
    int bytes = proc_listpids(PROC_UID_ONLY, getuid(), pids, (int)(capacity * sizeof(pid_t)));
    if (bytes < 0) { free(pids); return -1; }
    size_t count = (size_t)bytes / sizeof(pid_t);
    if (count > capacity) count = capacity;
    int written = 0;
    for (size_t i = 0; i < count; i++) if (pids[i] > 0 && bl_process_sample(pids[i], &out[written]) == 0) written++;
    free(pids);
    return written;
}
