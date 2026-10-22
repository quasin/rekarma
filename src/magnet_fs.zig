//! The filesystem half of `rekarma --magnet`: a read-only FUSE 3 view of a
//! torrent, built from its metadata and served piece-by-piece on demand.
//!
//! What it does not do matters as much as what it does: nothing here downloads
//! a whole torrent. readdir and getattr answer from the metadata snapshot, so a
//! 100 GB release is browsable the second its info dict arrives, and only the
//! bytes a reader actually asks for are ever waited on. A read that touches a
//! piece the swarm has not delivered yet blocks in magnet_shim's rek_bt_read
//! until it has, which is what lets `mpv /mnt/rel/movie.mkv` start on an
//! otherwise empty cache.
//!
//! libfuse's C API is bridged by src/fuse_glue.c; the callbacks below are what
//! it calls, and they never see a FUSE type.

const std = @import("std");
const tree_mod = @import("magnet_tree.zig");

pub const Tree = tree_mod.Tree;
pub const RemoteFile = tree_mod.RemoteFile;

/// Same values as libfuse's attributes: a directory (0555) or a read-only
/// regular file (0444). Set here because the glue only relays the numbers.
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;
const dir_mode: u32 = S_IFDIR | 0o555;
const file_mode: u32 = S_IFREG | 0o444;

const ENOENT: c_int = -2;
const EIO: c_int = -5;
const ENOTDIR: c_int = -20;
const EISDIR: c_int = -21;
const EINVAL: c_int = -22;
const ENODATA: c_int = -61;
const ETIMEDOUT: c_int = -110;

/// How long one read may wait for the swarm before failing. Long enough for a
/// slow first piece, short enough that a dead torrent does not leave a reader
/// hanging forever.
pub const read_timeout_ms: c_int = 120_000;

pub const Stat = extern struct {
    mode: u32,
    size: u64,
};

/// The mounted filesystem. libfuse's high-level callbacks receive no user data
/// (fuse_new's private_data never reaches them), and one process mounts one
/// torrent, so the state is module-level — set by mount() before any request
/// can arrive and cleared after the session ends.
var fs: ?*Tree = null;

pub fn mount(state: *Tree) void {
    fs = state;
}

pub fn unmount() void {
    fs = null;
}

fn current() ?*Tree {
    return fs;
}

// ─── engine and glue entry points ────────────────────────────────────────────

extern fn rek_bt_read(handle: ?*anyopaque, offset: u64, buf: [*]u8, len: usize, timeout_ms: c_int) i64;
extern fn rek_fuse_dir_entry(buf: ?*anyopaque, filler: ?*const anyopaque, name: [*]const u8, name_len: usize, is_dir: c_int, size: u64, next_offset: i64) c_int;

/// Mount @p mountpoint and serve it until a signal or an error ends the
/// session. Blocks the calling thread. Returns 0 or a negative errno.
pub fn run(mountpoint: [:0]const u8, fsname: [:0]const u8) c_int {
    return rek_fuse_run(mountpoint.ptr, fsname.ptr);
}

extern fn rek_fuse_run(mountpoint: [*:0]const u8, fsname: [*:0]const u8) c_int;

fn dirEntry(buf: ?*anyopaque, filler: ?*const anyopaque, name: []const u8, is_dir: bool, size: u64) c_int {
    return rek_fuse_dir_entry(buf, filler, name.ptr, name.len, @intFromBool(is_dir), size, 0);
}

// ─── callbacks called by src/fuse_glue.c ─────────────────────────────────────

export fn rek_fs_stat(path: [*:0]const u8, out: *Stat) c_int {
    const state = current() orelse return EIO;
    const index = state.lookup(std.mem.span(path)) orelse return ENOENT;
    const entry = state.at(index);
    out.* = .{
        .mode = if (entry.kind == .dir) dir_mode else file_mode,
        .size = if (entry.kind == .dir) 0 else entry.size,
    };
    return 0;
}

export fn rek_fs_readdir(path: [*:0]const u8, buf: ?*anyopaque, filler: ?*const anyopaque, offset: i64) c_int {
    _ = offset;
    const state = current() orelse return EIO;
    const index = state.lookup(std.mem.span(path)) orelse return ENOENT;
    const entry = state.at(index);
    if (entry.kind != .dir) return ENOTDIR;

    // "." and ".." first, as every walker expects; the kernel does not add them
    // on behalf of a filesystem that fills the buffer itself.
    if (dirEntry(buf, filler, ".", true, 0) != 0) return 0;
    if (dirEntry(buf, filler, "..", true, 0) != 0) return 0;
    for (entry.children.items) |child| {
        const node = state.at(child);
        if (dirEntry(buf, filler, node.name, node.kind == .dir, node.size) != 0) return 0;
    }
    return 0;
}

export fn rek_fs_open(path: [*:0]const u8, fh_out: *u64) c_int {
    const state = current() orelse return EIO;
    const index = state.lookup(std.mem.span(path)) orelse return ENOENT;
    if (state.at(index).kind == .dir) return EISDIR;
    // Node index plus one, so 0 can stand for "no handle".
    fh_out.* = @as(u64, index) + 1;
    return 0;
}

export fn rek_fs_read(fh: u64, buf: [*]u8, size: u64, offset: u64) i64 {
    const state = current() orelse return EIO;
    if (fh == 0) return EINVAL;
    const handle = fh - 1;
    if (handle >= state.nodes.items.len) return EINVAL;

    const entry = state.at(@intCast(handle));
    if (entry.kind != .file) return EISDIR;
    // Past the end is an ordinary short read, not an error: that is how `cat`
    // and mpv probe a size they already know.
    if (offset >= entry.size) return 0;
    const want: u64 = @min(size, entry.size - offset);
    if (want == 0) return 0;

    const read = rek_bt_read(state.engine.handle, entry.offset + offset, buf, want, read_timeout_ms);
    if (read < 0) {
        // -ETIMEDOUT is the swarm never delivering the piece; -ENODATA is a
        // torrent whose metadata or disk layer is not up yet. Both are the
        // reader's business, so they are passed through instead of flattened
        // into a generic EIO.
        if (read == ETIMEDOUT) return ETIMEDOUT;
        if (read == ENODATA) return ENODATA;
        return EIO;
    }
    return read;
}

export fn rek_fs_release(fh: u64) c_int {
    _ = fh;
    return 0;
}
