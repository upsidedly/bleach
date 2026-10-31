#include "BleachFS.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>

/* getattrlist packs fixed attributes on four-byte boundaries, including 64-bit
   values. PACK_INVAL_ATTRS keeps their offsets stable on other filesystems. */
typedef struct __attribute__((packed, aligned(4))) {
    uint32_t length;
    attribute_set_t returned;
    dev_t device;
    uint64_t inode;
    off_t private_size;
    uint64_t flags;
} StorageAttributes;

void bl_measure_storage(const char *path, const BLStat *s, BLStorage *out) {
    memset(out, 0, sizeof(*out));
    int64_t allocated = s->allocated > 0 ? s->allocated : 0;
    if (s->type == 3) {
        out->symbolic_links = 1;
        out->unverified_bytes = allocated;
        return; /* A reference never contributes its target's contents. */
    }
    if (s->type == 1 && s->links > 1) {
        out->hard_linked_files = 1;
        out->hard_linked_bytes = allocated;
        return; /* Unlinking one name does not release the inode's data. */
    }
    out->unverified_bytes = allocated;
    if (s->type != 1 || s->dataless) return;

    struct attrlist request = {0};
    request.bitmapcount = ATTR_BIT_MAP_COUNT;
    request.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_DEVID | ATTR_CMN_FILEID;
    request.forkattr = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_EXT_FLAGS;
    StorageAttributes value = {0};
    if (getattrlist(path, &request, &value, sizeof(value),
                    FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS) != 0) return;
    /* Never borrow metadata from a replaced entry or interpret an unsupported
       attribute's zero-filled slot as evidence of shared or private storage. */
    if (value.length != sizeof(value) ||
        (value.returned.commonattr & request.commonattr) != request.commonattr ||
        (uint64_t)value.device != s->device || value.inode != s->inode) return;
    if (value.returned.forkattr & ATTR_CMNEXT_EXT_FLAGS) {
        out->clone_files = (value.flags & EF_SHARES_ALL_BLOCKS) != 0;
    }
    if (!(value.returned.forkattr & ATTR_CMNEXT_PRIVATESIZE) || value.private_size < 0) return;
    out->unverified_bytes = 0;
    out->private_bytes = value.private_size < allocated ? value.private_size : allocated;
    out->shared_bytes = allocated - out->private_bytes;
    out->shared_files = out->shared_bytes > 0;
    /* EF_MAY_SHARE_BLOCKS can remain set after the other clone is deleted.
       Only the current private-size result determines the byte buckets. */
}

void bl_add_storage(BLStorage *total, const BLStorage *item) {
    total->private_bytes += item->private_bytes;
    total->shared_bytes += item->shared_bytes;
    total->hard_linked_bytes += item->hard_linked_bytes;
    total->unverified_bytes += item->unverified_bytes;
    total->shared_files += item->shared_files;
    total->clone_files += item->clone_files;
    total->hard_linked_files += item->hard_linked_files;
    total->symbolic_links += item->symbolic_links;
}
