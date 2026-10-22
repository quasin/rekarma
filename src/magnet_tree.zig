//! The tree behind `rekarma --magnet`: a torrent's file list turned into the
//! directory structure a mounted filesystem walks, with every file's byte range
//! in the torrent's byte space.
//!
//! Pure data, deliberately: no FUSE types and no engine calls live here, so the
//! mapping from "path + offset of this file" to "offset in the torrent" — the
//! one place a torrent can hand out the wrong bytes — is unit-testable on its
//! own.

const std = @import("std");

/// One file of the torrent, exactly as magnet_shim reports it: paths are
/// relative, '/'-separated and carry the torrent name as their first component.
pub const RemoteFile = extern struct {
    path: [*:0]const u8,
    size: i64,
    /// Start of the file in the torrent's byte space.
    offset: i64,
};

/// What the filesystem needs from the engine; opaque here.
pub const Engine = struct {
    handle: ?*anyopaque,
};

pub const Kind = enum { dir, file };

pub const Node = struct {
    /// Absolute path inside the mount ("/rel/a.bin"), owned by the tree.
    path: []u8,
    /// Last component, borrowed from `path`.
    name: []const u8,
    kind: Kind,
    /// Byte range in the torrent's byte space. Files are laid end-to-end there
    /// by the torrent's metadata, which is the whole reason a per-file offset
    /// can be turned into torrent bytes at all.
    offset: u64 = 0,
    size: u64 = 0,
    children: std.ArrayListUnmanaged(u32) = .empty,
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    engine: Engine,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    /// The torrent's own name, used as the mount's fsname.
    name: []u8 = &.{},

    /// Build the tree from the torrent's metadata. The mount root holds the
    /// torrent's content directory, because the metadata paths start with the
    /// torrent name — that is what a release looks like on disk.
    pub fn init(allocator: std.mem.Allocator, engine: Engine, name: []const u8, files: []const RemoteFile) !Tree {
        var self: Tree = .{ .allocator = allocator, .engine = engine };
        errdefer self.deinit();
        self.name = try allocator.dupe(u8, name);

        const root = try self.addNode("/", .dir);
        std.debug.assert(root == 0);

        for (files) |file| {
            const path = std.mem.span(file.path);
            if (path.len == 0 or file.size < 0) continue;

            // Components are collected before any node is created: whether one
            // names the file itself or a directory on the way to it depends on
            // what follows it.
            var components: std.ArrayListUnmanaged([]const u8) = .empty;
            defer components.deinit(allocator);
            var parts = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
            while (parts.next()) |part| {
                // "." and ".." are dropped rather than resolved: a torrent must
                // not be able to place a node above the mount point.
                if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) continue;
                try components.append(allocator, part);
            }
            if (components.items.len == 0) continue;

            var full: std.ArrayListUnmanaged(u8) = .empty;
            defer full.deinit(allocator);
            try full.append(allocator, '/');

            var parent: u32 = root;
            for (components.items, 0..) |part, i| {
                if (i != 0) try full.append(allocator, '/');
                try full.appendSlice(allocator, part);
                if (i + 1 == components.items.len) {
                    _ = try self.addChild(parent, full.items, .file, @intCast(file.offset), @intCast(file.size));
                } else {
                    parent = self.findChild(parent, part) orelse
                        try self.addChild(parent, full.items, .dir, 0, 0);
                }
            }
        }
        return self;
    }

    pub fn deinit(self: *Tree) void {
        for (self.nodes.items) |*entry| {
            self.allocator.free(entry.path);
            entry.children.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.by_path.deinit(self.allocator);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    fn addNode(self: *Tree, path: []const u8, kind: Kind) !u32 {
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .path = owned,
            .name = if (std.mem.eql(u8, path, "/")) "" else std.fs.path.basename(owned),
            .kind = kind,
        });
        try self.by_path.put(self.allocator, owned, index);
        return index;
    }

    fn addChild(self: *Tree, parent: u32, path: []const u8, kind: Kind, offset: u64, size: u64) !u32 {
        const index = try self.addNode(path, kind);
        self.nodes.items[index].offset = offset;
        self.nodes.items[index].size = size;
        try self.nodes.items[parent].children.append(self.allocator, index);
        return index;
    }

    fn findChild(self: *Tree, parent: u32, name: []const u8) ?u32 {
        // A directory in a release holds tens of entries at most; scanning keeps
        // the tree one flat allocation instead of a hash map per directory.
        for (self.nodes.items[parent].children.items) |child| {
            if (std.mem.eql(u8, self.nodes.items[child].name, name)) return child;
        }
        return null;
    }

    pub fn lookup(self: *const Tree, path: []const u8) ?u32 {
        return self.by_path.get(path);
    }

    pub fn nodeCount(self: *const Tree) usize {
        return self.nodes.items.len;
    }

    pub fn at(self: *const Tree, index: u32) *const Node {
        return &self.nodes.items[index];
    }
};

test "metadata paths become a directory tree with torrent offsets" {
    const allocator = std.testing.allocator;
    var files = [_]RemoteFile{
        .{ .path = "rel/a.bin", .size = 300, .offset = 100 },
        .{ .path = "rel/sub/b.bin", .size = 50, .offset = 400 },
        // A hostile path must not climb out of the mount.
        .{ .path = "rel/../../escape.txt", .size = 1, .offset = 450 },
    };
    var tree = try Tree.init(allocator, .{ .handle = null }, "rel", &files);
    defer tree.deinit();

    // root, /rel, /rel/a.bin, /rel/sub, /rel/sub/b.bin, /rel/escape.txt
    try std.testing.expectEqual(@as(usize, 6), tree.nodeCount());

    const a = tree.lookup("/rel/a.bin") orelse return error.MissingFile;
    try std.testing.expectEqual(@as(u64, 100), tree.at(a).offset);
    try std.testing.expectEqual(@as(u64, 300), tree.at(a).size);
    try std.testing.expectEqualStrings("a.bin", tree.at(a).name);

    const dir = tree.lookup("/rel/sub") orelse return error.MissingDir;
    try std.testing.expect(tree.at(dir).kind == .dir);
    try std.testing.expect(tree.lookup("/rel/sub/b.bin") != null);
    try std.testing.expect(tree.lookup("/escape.txt") == null);
    const rel = tree.lookup("/rel") orelse return error.MissingRel;
    try std.testing.expectEqual(@as(usize, 3), tree.at(rel).children.items.len);
    const sub = tree.lookup("/rel/sub") orelse return error.MissingSub;
    try std.testing.expectEqual(@as(usize, 1), tree.at(sub).children.items.len);
}

test "a single-file torrent still hangs off a directory" {
    const allocator = std.testing.allocator;
    var files = [_]RemoteFile{
        .{ .path = "solo.iso", .size = 4096, .offset = 0 },
    };
    var tree = try Tree.init(allocator, .{ .handle = null }, "solo.iso", &files);
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 2), tree.nodeCount());
    const root = tree.lookup("/") orelse return error.MissingRoot;
    try std.testing.expectEqual(@as(usize, 1), tree.at(root).children.items.len);
    try std.testing.expect(tree.lookup("/solo.iso") != null);
}
