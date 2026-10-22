/*
 * libfuse3 glue for `rekarma --magnet`.
 *
 * FUSE's high-level API is a struct of C function pointers and a struct stat
 * apiece — layout-heavy types that are not worth translating into Zig. This file
 * owns all of that and hands the filesystem's real work to three plain Zig
 * callbacks (rek_fs_stat / rek_fs_readdir / rek_fs_open / rek_fs_read /
 * rek_fs_release), which deal only in paths, sizes, modes and byte buffers.
 *
 * The mount is read-only by construction: the export is a torrent, and a write
 * through the mount could only ever be discarded. `-o ro` states that to the
 * kernel so a write fails in the VFS instead of in a callback.
 */
/* FUSE API 312 (libfuse 3.12+): the versioned entry points and the
 * fuse_loop_cfg_* configuration used below. */
#define FUSE_USE_VERSION 312

#include <fuse3/fuse.h>
#include <fuse3/fuse_lowlevel.h> // fuse_session_exited()

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* What a Zig stat callback fills in; the rest of struct stat is ours. */
struct rek_fuse_stat {
    uint32_t mode;
    uint64_t size;
};

extern int rek_fs_stat(const char* path, struct rek_fuse_stat* out);
extern int rek_fs_readdir(const char* path, void* buf, const void* filler, off_t offset);
extern int rek_fs_open(const char* path, uint64_t* fh_out);
extern int64_t rek_fs_read(uint64_t fh, void* buf, uint64_t size, uint64_t offset);
extern int rek_fs_release(uint64_t fh);

/* One directory entry for rek_fs_readdir: the filler wants a NUL-terminated
 * name, the Zig side has a slice, so the copy happens here. */
int rek_fuse_dir_entry(void* buf, const void* filler, const char* name, size_t name_len,
                       int is_dir, uint64_t size, off_t next_offset) {
    char copy[512];
    if (name_len >= sizeof(copy)) return -ENAMETOOLONG;
    memcpy(copy, name, name_len);
    copy[name_len] = '\0';

    struct stat st;
    memset(&st, 0, sizeof(st));
    /* S_IFDIR/S_IFREG live in sys/stat.h behind feature-test macros that a
     * plain -std=c11 build does not define; the octal values are the ABI. */
    st.st_mode  = is_dir ? (0040000 | 0555) : (0100000 | 0444);
    st.st_size  = (off_t)size;
    st.st_nlink = 1;
    st.st_uid   = getuid();
    st.st_gid   = getgid();

    fuse_fill_dir_t fill = (fuse_fill_dir_t)filler;
    return fill(buf, copy, &st, next_offset, (enum fuse_fill_dir_flags)0);
}

static int glue_getattr(const char* path, struct stat* st, struct fuse_file_info* fi) {
    (void)fi;
    struct rek_fuse_stat rs;
    memset(&rs, 0, sizeof(rs));
    int rc = rek_fs_stat(path, &rs);
    if (rc != 0) return rc;

    memset(st, 0, sizeof(*st));
    st->st_mode  = (mode_t)rs.mode;
    st->st_size  = (off_t)rs.size;
    st->st_nlink = (rs.mode & 0170000) == 0040000 ? 2 : 1;
    st->st_uid   = getuid();
    st->st_gid   = getgid();
    st->st_blksize = 128 * 1024;
    return 0;
}

static int glue_readdir(const char* path, void* buf, fuse_fill_dir_t filler, off_t offset,
                        struct fuse_file_info* fi, enum fuse_readdir_flags flags) {
    (void)fi;
    (void)flags;
    return rek_fs_readdir(path, buf, (const void*)filler, offset);
}

static int glue_open(const char* path, struct fuse_file_info* fi) {
    if ((fi->flags & O_ACCMODE) != O_RDONLY) return -EACCES;
    uint64_t fh = 0;
    int rc = rek_fs_open(path, &fh);
    if (rc != 0) return rc;
    fi->fh = fh;
    /* Our bytes never change under a reader, so the kernel may keep pages it
       has already fetched; a second read of the same file costs no swarm
       traffic. Lookups stay cheap for the same reason. */
    fi->keep_cache = 1;
    return 0;
}

static int glue_read(const char* path, char* buf, size_t size, off_t offset,
                     struct fuse_file_info* fi) {
    (void)path;
    int64_t n = rek_fs_read(fi->fh, buf, size, (uint64_t)offset);
    if (n < 0) return (int)n;
    return (int)n;
}

static int glue_release(const char* path, struct fuse_file_info* fi) {
    (void)path;
    return rek_fs_release(fi->fh);
}

static const struct fuse_operations rek_ops = {
    .getattr = glue_getattr,
    .open    = glue_open,
    .read    = glue_read,
    .readdir = glue_readdir,
    .release = glue_release,
};

/*
 * Mount at @p mountpoint, serve requests until a signal or an error stops the
 * session, then unmount. Blocks the calling thread; returns 0 or -errno.
 */
int rek_fuse_run(const char* mountpoint, const char* fsname) {
    char options[512];
    snprintf(options, sizeof(options),
             "ro,fsname=%s,subtype=%s,default_permissions,auto_unmount",
             fsname ? fsname : "rekarma", fsname ? fsname : "rekarma");

    char* argv[] = {(char*)"rekarma", (char*)"-o", options, NULL};
    struct fuse_args args = FUSE_ARGS_INIT(3, argv);

    struct fuse* fuse = fuse_new(&args, &rek_ops, sizeof(rek_ops), NULL);
    if (!fuse) {
        fuse_opt_free_args(&args);
        return -ENOMEM;
    }

    if (fuse_mount(fuse, mountpoint) != 0) {
        fuse_destroy(fuse);
        fuse_opt_free_args(&args);
        return -EINVAL;
    }

    struct fuse_session* session = fuse_get_session(fuse);
    if (fuse_set_signal_handlers(session) != 0) {
        fuse_unmount(fuse);
        fuse_destroy(fuse);
        fuse_opt_free_args(&args);
        return -EINVAL;
    }

    struct fuse_loop_config* loop = fuse_loop_cfg_create();
    fuse_loop_cfg_set_clone_fd(loop, 1);
    /* Many worker threads: a read blocks until its pieces arrive, and a player
       keeps several reads in flight (readahead plus its own buffers). With too
       few workers the requests behind them — including the lookups another
       program does — queue behind a wait they did not ask for. */
    fuse_loop_cfg_set_max_threads(loop, 32);

    int rc = fuse_loop_mt(fuse, loop);
    // A loop stopped by SIGINT/SIGTERM (or by umount) is the normal way this
    // ends; only a loop that died with the session still live is an error.
    const int exited = fuse_session_exited(session);

    fuse_loop_cfg_destroy(loop);
    fuse_remove_signal_handlers(session);
    fuse_unmount(fuse);
    fuse_destroy(fuse);
    fuse_opt_free_args(&args);
    if (rc != 0 && !exited) return -EIO;
    return 0;
}
