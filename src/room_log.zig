//! The on-disk record of one pubsub room: the last `max` messages, kept in
//! memory and mirrored to a file, so a restart continues the same log instead
//! of starting a fresh one.

const std = @import("std");
const Io = std.Io;

/// Hand-off between the librats reactor thread and the main loop. std.Thread.Mutex
/// is gone in Zig 0.17 and std.Io.Mutex wants an Io handle the reactor thread does
/// not own, so this is the blocking spinlock the 0.17 notes suggest: both critical
/// sections are a handful of microseconds, so spinning costs nothing.
pub const Spinlock = struct {
    state: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *Spinlock) void {
        while (!self.state.tryLock()) std.Thread.yield() catch {};
    }

    pub fn unlock(self: *Spinlock) void {
        self.state.unlock();
    }
};

/// The last `max` lines of one room, as a sliding window over the file.
pub const RoomLog = struct {
    gpa: std.mem.Allocator,
    /// Owned. The file this room is recorded in.
    path: []u8,
    /// How many of the most recent messages are kept and shown.
    max: usize,
    lines: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, path: []const u8, max: usize) !RoomLog {
        return .{
            .gpa = gpa,
            .path = try gpa.dupe(u8, path),
            // A cap of 0 would record nothing at all, which no caller means.
            .max = @max(max, 1),
        };
    }

    pub fn deinit(self: *RoomLog) void {
        for (self.lines.items) |line| self.gpa.free(line);
        self.lines.deinit(self.gpa);
        self.gpa.free(self.path);
    }

    /// Pick up the log an earlier run left behind and apply this run's cap to it:
    /// an existing file is trimmed to its last `max` lines, and a missing one is
    /// created empty so the room always has a file on disk.
    pub fn load(self: *RoomLog, io: Io) !void {
        const bytes = Io.Dir.cwd().readFileAlloc(io, self.path, self.gpa, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => &.{},
            else => return err,
        };
        defer self.gpa.free(bytes);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (line.len != 0) try self.push(line);
        }
        try self.rewrite(io);
    }

    /// Record one received message.
    pub fn append(self: *RoomLog, io: Io, line: []const u8) !void {
        try self.push(line);
        try self.rewrite(io);
    }

    fn push(self: *RoomLog, line: []const u8) !void {
        const copy = try self.gpa.dupe(u8, line);
        errdefer self.gpa.free(copy);
        if (self.lines.items.len == self.max) self.gpa.free(self.lines.orderedRemove(0));
        try self.lines.append(self.gpa, copy);
    }

    /// The cap makes the file a window, and only a full rewrite can drop the
    /// oldest line, so every write is a rewrite. `max` bounds it — 1000 lines by
    /// default — which keeps it one small write per message.
    fn rewrite(self: *RoomLog, io: Io) !void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        for (self.lines.items) |line| {
            try bytes.appendSlice(self.gpa, line);
            try bytes.append(self.gpa, '\n');
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path, .data = bytes.items });
    }

    /// Write at most the `n` most recent messages, oldest first.
    pub fn writeTail(self: *RoomLog, n: usize, out: *Io.Writer) !void {
        const start = self.lines.items.len -| n;
        for (self.lines.items[start..]) |line| try out.print("{s}\n", .{line});
    }
};

test "the log keeps only the last max lines" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // RoomLog resolves its path against the cwd, so the file has to be named the
    // same way: .zig-cache/tmp/<name> is where tmpDir() puts it.
    const file = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/room.txt", .{tmp.sub_path});
    defer gpa.free(file);

    const io = std.testing.io;
    var log = try RoomLog.init(gpa, file, 2);
    defer log.deinit();

    const samples = [_][]const u8{ "a", "b", "c" };
    for (samples) |line| try log.append(io, line);
    try std.testing.expectEqual(@as(usize, 2), log.lines.items.len);
    try std.testing.expectEqualStrings("b", log.lines.items[0]);
    try std.testing.expectEqualStrings("c", log.lines.items[1]);

    const on_disk = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1 << 16));
    defer gpa.free(on_disk);
    try std.testing.expectEqualStrings("b\nc\n", on_disk);
}
