//! `rekarma --magnet`: mount a release and read it while it downloads.
//!
//! The mode is one long-lived process with two halves. The engine half
//! (magnet_shim.cpp) owns a librats bittorrent session and answers "is this
//! piece here yet" and "give me these bytes"; the filesystem half
//! (magnet_fs.zig, fuse_glue.c) turns the torrent's metadata into a read-only
//! tree and asks the engine for exactly the bytes a reader touches. Nothing
//! asks for the whole torrent, so browsing a release costs its info dict and
//! playing one file costs that file's pieces.
//!
//! This file is the glue between the two: open the session, wait for the
//! metadata, print the file tree, mount, and stay in the FUSE loop until the
//! mount is signalled away.

const std = @import("std");
const Io = std.Io;
const fs = @import("magnet_fs.zig");
const tree_mod = @import("magnet_tree.zig");
const tracker = @import("tracker.zig");

/// How long to wait for the info dict (BEP 9) before giving up. The DHT round
/// is ~40 s, and a magnet whose only peer source is a tracker can take longer.
pub const metadata_timeout_ms: u32 = 120_000;

/// One peer given on the command line (--connect), dialed directly by the
/// torrent as well as by the node: for a hand-wired run and for a magnet with
/// no trackers and no DHT.
pub const Peer = struct {
    host: []const u8,
    port: u16,
};

/// A cheap shape check, so a typo is refused in the foreground instead of
/// becoming a daemon that starts, fails inside the child and leaves the user
/// with a pid file and an empty log. The shim parses the link for real.
pub fn looksValid(link: []const u8) bool {
    const forms = [_][]const u8{ "magnet:", "magnet:?", "xt=urn:btih:", "urn:btih:", "btih:" };
    for (forms) |prefix| {
        if (std.mem.startsWith(u8, link, prefix)) return true;
    }
    var hex: usize = 0;
    var base32: usize = 0;
    for (link) |byte| {
        if (std.ascii.isHex(byte)) hex += 1;
        if ((byte >= 'A' and byte <= 'Z') or (byte >= '2' and byte <= '7')) base32 += 1;
    }
    return (link.len == 40 and hex == 40) or (link.len == 32 and base32 == 32);
}

pub const Params = struct {
    /// A magnet link (or bare info-hash) that names the release, or — with
    /// `torrent` — the path of a .torrent file that carries its metadata.
    source: []const u8,
    /// `source` is a .torrent file: the info dict is read from disk instead of
    /// being fetched from peers (BEP 9), so no swarm is needed to browse it.
    torrent: bool = false,
    /// Where to mount; null = "mnt/<torrent name>".
    mount: ?[]const u8 = null,
    /// Where pieces are written and kept; null = ".rekarma".
    cache: ?[]const u8 = null,
    port: u16 = 0,
    dht: bool = true,
    peers: []const Peer = &.{},
};

/// The shim's C ABI (src/magnet_shim.cpp). The file list is borrowed from the
/// session and valid until rek_bt_close.
/// magnet_tree owns the layout of one file entry; the shim returns an array of
/// exactly this, so there is one definition rather than a copy that can drift.
const BtFile = tree_mod.RemoteFile;

const BtProgress = extern struct {
    has_metadata: c_int,
    total_size: u64,
    downloaded: u64,
    peers: usize,
    progress: f64,
};

extern fn rek_bt_open(magnet: [*:0]const u8, cache: [*:0]const u8, port: u16, dht: c_int, err: [*]u8, err_len: usize) ?*anyopaque;
extern fn rek_bt_open_torrent(path: [*:0]const u8, cache: [*:0]const u8, port: u16, dht: c_int, err: [*]u8, err_len: usize) ?*anyopaque;
extern fn rek_bt_close(handle: ?*anyopaque) void;
extern fn rek_bt_tracker_count(handle: ?*anyopaque) usize;
extern fn rek_bt_tracker_url(handle: ?*anyopaque, index: usize, buf: [*]u8, len: usize) usize;
extern fn rek_bt_identity(handle: ?*anyopaque, info_hash_hex: [*]u8, peer_id_hex: [*]u8, len: usize) void;
extern fn rek_bt_listen_port(handle: ?*anyopaque) u16;
extern fn rek_bt_add_peer(handle: ?*anyopaque, host: [*:0]const u8, port: u16) void;
extern fn rek_bt_wait_metadata(handle: ?*anyopaque, timeout_ms: c_int) c_int;
extern fn rek_bt_name(handle: ?*anyopaque) [*:0]const u8;
extern fn rek_bt_num_files(handle: ?*anyopaque) usize;
extern fn rek_bt_files(handle: ?*anyopaque) ?[*]const BtFile;
extern fn rek_bt_total_size(handle: ?*anyopaque) u64;
extern fn rek_bt_num_pieces(handle: ?*anyopaque) u32;
extern fn rek_bt_piece_length(handle: ?*anyopaque) u32;
extern fn rek_bt_state(handle: ?*anyopaque, out: *BtProgress) void;

pub fn run(io: Io, gpa: std.mem.Allocator, out: *Io.Writer, params: Params) !void {
    const source_z = try gpa.dupeSentinel(u8, params.source, 0);
    defer gpa.free(source_z);
    const cache = params.cache orelse ".rekarma";
    const cache_z = try gpa.dupeSentinel(u8, cache, 0);
    defer gpa.free(cache_z);

    // Zeroed so a failure with an empty message still prints something sane.
    var err_buf: [256]u8 = @splat(0);
    const opened = if (params.torrent)
        rek_bt_open_torrent(source_z.ptr, cache_z.ptr, params.port, @intFromBool(params.dht), &err_buf, err_buf.len)
    else
        rek_bt_open(source_z.ptr, cache_z.ptr, params.port, @intFromBool(params.dht), &err_buf, err_buf.len);
    const handle = opened orelse {
        try out.print("rekarma: {s}\n", .{std.mem.sliceTo(&err_buf, 0)});
        try out.flush();
        std.process.exit(1);
    };
    defer rek_bt_close(handle);

    try announceHttpsTrackers(io, gpa, handle, out, .started);

    for (params.peers) |peer| {
        const host_z = try gpa.dupeSentinel(u8, peer.host, 0);
        defer gpa.free(host_z);
        rek_bt_add_peer(handle, host_z.ptr, peer.port);
    }

    try out.print("cache    {s}\n", .{cache});
    if (params.torrent) {
        // The metadata is in the file: there is nothing to wait for but the
        // one poll below, which is why this mode also works with no peers.
        try out.print("torrent  {s}\n", .{params.source});
        try out.print("reading the .torrent metadata…\n", .{});
    } else {
        try out.print("waiting for the release's metadata (BEP 9)…\n", .{});
    }
    try out.flush();

    // Ask in one-second slices so the wait can say something instead of looking
    // like a hang: the first peers of a magnet are the slow part.
    var waited: u32 = 0;
    while (rek_bt_wait_metadata(handle, 1000) != 0) {
        waited += 1000;
        if (waited >= metadata_timeout_ms) {
            if (params.torrent) {
                try out.print("rekarma: the .torrent metadata did not become available after {d}s\n", .{waited / 1000});
            } else {
                try out.print("rekarma: no metadata after {d}s — no peer served the info dict\n", .{waited / 1000});
                try out.print("         a magnet needs a peer: a tracker, the DHT (--no-dht turns it off) or --connect\n", .{});
            }
            try out.flush();
            std.process.exit(1);
        }
        if (waited % 5000 == 0) {
            var state: BtProgress = undefined;
            rek_bt_state(handle, &state);
            try out.print("         {d}s, {d} peer(s), {d:.1}% of the release so far\n", .{
                waited / 1000, state.peers, state.progress * 100.0,
            });
            try out.flush();
        }
    }

    const name = std.mem.span(rek_bt_name(handle));
    const num_files = rek_bt_num_files(handle);
    const files_ptr = rek_bt_files(handle) orelse {
        try out.print("rekarma: the release has no files\n", .{});
        try out.flush();
        std.process.exit(1);
    };
    const files = files_ptr[0..num_files];

    var tree = try tree_mod.Tree.init(gpa, .{ .handle = handle }, name, files);
    defer tree.deinit();

    try out.print("{s} — {d} file(s), {f}, {d} piece(s) of {f}\n", .{
        name, num_files, humanSize(rek_bt_total_size(handle)), rek_bt_num_pieces(handle), humanSize(rek_bt_piece_length(handle)),
    });
    try printTree(out, &tree);

    const mountpoint = params.mount orelse try defaultMountpoint(gpa, name);
    defer if (params.mount == null) gpa.free(mountpoint);
    Io.Dir.cwd().createDirPath(io, mountpoint) catch |err| {
        try out.print("rekarma: cannot create the mount point {s}: {s}\n", .{ mountpoint, @errorName(err) });
        try out.flush();
        std.process.exit(1);
    };

    const mount_z = try gpa.dupeSentinel(u8, mountpoint, 0);
    defer gpa.free(mount_z);
    const name_z = try gpa.dupeSentinel(u8, name, 0);
    defer gpa.free(name_z);

    fs.mount(&tree);
    try out.print("\nmounted  {s} (read-only, open files read on demand)\n", .{mountpoint});
    try out.print("         nothing is downloaded until a file is read; unmount with umount or Ctrl-C\n", .{});
    try out.flush();

    const rc = fs.run(mount_z, name_z);
    fs.unmount();

    // Tell an https tracker we are gone, so it does not hold the peer slot (and
    // a private tracker does not read the next run as a second client).
    announceHttpsTrackers(io, gpa, handle, out, .stopped) catch {};

    var state: BtProgress = undefined;
    rek_bt_state(handle, &state);
    try out.print("\nunmounted {s} — {f} of {f} fetched ({d:.1}%), {d} peer(s)\n", .{
        mountpoint, humanSize(state.downloaded), humanSize(state.total_size), state.progress * 100.0, state.peers,
    });
    if (rc != 0) try out.print("rekarma: the mount ended with an error ({d})\n", .{rc});
    try out.flush();
}

/// Announce to the trackers the engine cannot reach.
///
/// librats has no TLS: it refuses an `https://` tracker outright, and since a
/// private tracker's swarm is not on the DHT, such a release would otherwise
/// mount and then wait forever for pieces. The announce is made from here
/// (tracker.zig, through std.http.Client) and the peers are handed to the
/// engine, which treats them like any other peer source.
fn announceHttpsTrackers(
    io: Io,
    gpa: std.mem.Allocator,
    handle: ?*anyopaque,
    out: *Io.Writer,
    event: tracker.Params.Event,
) !void {
    const count = rek_bt_tracker_count(handle);
    if (count == 0) return;

    var info_hash_hex: [41]u8 = undefined;
    var peer_id_hex: [41]u8 = undefined;
    rek_bt_identity(handle, &info_hash_hex, &peer_id_hex, info_hash_hex.len);

    var state: BtProgress = undefined;
    rek_bt_state(handle, &state);

    var index: usize = 0;
    while (index < count) : (index += 1) {
        var url_buf: [512]u8 = undefined;
        const len = rek_bt_tracker_url(handle, index, &url_buf, url_buf.len);
        if (len == 0) continue;
        const url = url_buf[0..len];
        // http and udp trackers are librats' own business.
        if (!std.mem.startsWith(u8, url, "https://")) continue;

        const announced = tracker.announce(gpa, io, url, .{
            .info_hash = hexToBytes(20, info_hash_hex[0..40]) orelse return,
            .peer_id = hexToBytes(20, peer_id_hex[0..40]) orelse return,
            .port = rek_bt_listen_port(handle),
            .left = state.total_size -| state.downloaded,
            .event = event,
        }) catch |err| {
            if (event == .started) {
                try out.print("tracker  {s}: {s}\n", .{ url, @errorName(err) });
                try out.flush();
            }
            continue;
        };

        if (announced.failure().len > 0) {
            if (event == .started) {
                try out.print("tracker  {s}: {s}\n", .{ url, announced.failure() });
                try out.print("         a private tracker allows one peer per passkey: close the other\n" ++
                    "         client, or pass -p with the port it announced from\n", .{});
                try out.flush();
            }
            continue;
        }

        // A "stopped" announce only tells the tracker we are leaving; its peer
        // list is not interesting and is not dialled.
        if (event == .stopped) continue;

        for (announced.peers[0..announced.peer_count]) |*peer| {
            var host_buf: [17]u8 = undefined;
            @memcpy(host_buf[0..peer.host_len], peer.host[0..peer.host_len]);
            host_buf[peer.host_len] = 0;
            rek_bt_add_peer(handle, host_buf[0..peer.host_len :0].ptr, peer.port);
        }
        try out.print("tracker  {s}: {d} peer(s){s}\n", .{
            url, announced.peer_count, if (announced.skipped_v6 > 0) " (IPv6 peers skipped)" else "",
        });
        try out.flush();
    }
}

fn hexToBytes(comptime n: usize, hex: []const u8) ?[n]u8 {
    if (hex.len != n * 2) return null;
    var out: [n]u8 = undefined;
    for (0..n) |i| {
        out[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return null;
    }
    return out;
}

/// "mnt/<name>": a mountpoint inside the cwd, so one run leaves one directory
/// next to the room's file and `--mount` is only needed to put it elsewhere.
fn defaultMountpoint(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    // A torrent name is attacker-controlled; keep it a single path component.
    const safe = try gpa.dupe(u8, name);
    defer gpa.free(safe);
    for (safe) |*byte| {
        if (byte.* == '/' or byte.* == '\\' or byte.* == ':') byte.* = '_';
    }
    return std.fmt.allocPrint(gpa, "mnt/{s}", .{safe});
}

fn printTree(out: *Io.Writer, tree: *tree_mod.Tree) !void {
    for (tree.nodes.items, 0..) |node, index| {
        if (index == 0) continue;
        // Depth from the path, so a nested release reads like a tree without a
        // recursive walker.
        var depth: usize = 0;
        for (node.path) |byte| {
            if (byte == '/') depth += 1;
        }
        try out.splatByteAll(' ', depth * 2);
        switch (node.kind) {
            .dir => try out.print("{s}/\n", .{node.name}),
            .file => try out.print("{s}  {f}\n", .{ node.name, humanSize(node.size) }),
        }
    }
    try out.flush();
}

fn humanSize(bytes: u64) HumanSize {
    return .{ .bytes = bytes };
}

/// Prints as "12.3 MB" through the formatter, so every caller gets the same
/// wording (`{f}` with humanSize(...)).
const HumanSize = struct {
    bytes: u64,

    pub fn format(self: HumanSize, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
        var value: f64 = @floatFromInt(self.bytes);
        var unit: usize = 0;
        while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) value /= 1024.0;
        if (unit == 0) {
            try writer.print("{d} {s}", .{ self.bytes, units[0] });
        } else {
            try writer.print("{d:.1} {s}", .{ value, units[unit] });
        }
    }
};
