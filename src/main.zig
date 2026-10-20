const std = @import("std");
const Io = std.Io;
const c = @import("c");
const room_log = @import("room_log.zig");

/// One room and one file for everyone who just runs the program; --room and
/// --file are how a second room — or a second log of the same one — is chosen.
const default_room = "rekarma";
const default_file = "all.txt";
const default_count: usize = 1000;

/// The version of this program, taken from build.zig.zon by build.zig (there is
/// no accessor for the manifest at runtime): the manifest stays the one place a
/// release is bumped. The librats half of --version needs no constant at all —
/// it is read out of the linked library.
const version = @import("build_options").version;

/// Bound into the librats handshake: a node of a different app cannot connect.
const protocol = "rekarma/1.0";

/// How long a message given on the command line waits for a peer before it is
/// published anyway, in seconds. The DHT needs its bootstrap plus one 30 s
/// announce/search round before it has anybody to offer, while mDNS or a
/// --connect peer answer within about a second — waiting 90 s for a LAN peer
/// would be silly, and waiting 5 s for the DHT is the same as not waiting.
const publish_wait_with_dht: u32 = 90;
const publish_wait_without_dht: u32 = 5;

/// How long a one-shot send (a message on the command line) keeps the node up
/// after rats_publish() returns. The call only hands the bytes to a librats
/// reactor thread, so exiting in the same breath would cut that write off before
/// it reached the wire. A peer on localhost happens to receive the message with
/// no delay at all, which is why this is margin and not a measured lower bound.
const send_drain_ms: u32 = 1000;

/// SIGINT/SIGTERM land here. It is atomic because the handler runs on whichever
/// thread the kernel picked; only the main loop reads it.
var stop = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        // Stdout is a pipe and its reader left (rekarma | head): stopping quietly
        // is the right answer, an error trace is not.
        error.WriteFailed => std.process.exit(0),
        else => return err,
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    // The command line has to outlive the node, and every string in it is small:
    // an arena released at exit beats tracking each dupe and each node argument.
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const opts = try parseArgs(arena, args);
    if (opts.problem) |problem| {
        try out.print("rekarma: {s}\n\n", .{problem});
        try printUsage(out);
        try out.flush();
        std.process.exit(2);
    }
    if (opts.help) {
        try printUsage(out);
        try out.flush();
        return;
    }
    // Like --help, this answers a question about the program rather than doing
    // the program's work: no daemon is forked and no node is created.
    if (opts.version) {
        try printVersions(out);
        try out.flush();
        return;
    }

    const log_path = try roomFilePath(arena, opts.file, opts.room);

    // Detached first, before anything else a node does: the fork inside is only
    // safe while this process is still one thread.
    if (opts.daemon) try daemonize(arena, io, out, log_path, opts);

    // A message on the command line is a one-shot send: publishing is the whole
    // job, so the room's file is never opened — load() rewrites the file it is
    // given, and a sender that creates or trims the recorder's log is a side
    // effect nobody asked for. --stay is the behaviour of sending and then
    // recording, the daemon is the node that records and nothing else.
    const send_only = opts.message.items.len != 0 and !opts.daemon and !opts.stay and !opts.show;

    var log: room_log.RoomLog = undefined;
    if (!send_only) {
        log = try room_log.RoomLog.init(gpa, log_path, opts.count);
        log.load(io) catch |err| {
            try out.print("rekarma: cannot open the room's log {s}: {s}\n", .{ log_path, @errorName(err) });
            try out.flush();
            std.process.exit(1);
        };
    }
    defer {
        if (!send_only) log.deinit();
    }

    // --show is a pure reader: it prints what a later run would work with.
    if (opts.show) {
        try log.writeTail(opts.count, out);
        try out.flush();
        return;
    }

    // Installed before anything that can block (DHT bootstrap, a dial, the wait
    // for a peer below): Ctrl-C has to stop a node that is still starting up.
    installSignalHandlers();

    try printBanner(out);

    // librats' own INFO logs go to stdout, where this program prints the room, so
    // at the default level they land between log lines; WARN (and librats' errors,
    // which go to stderr) keeps stdout a clean message stream. -v brings them back.
    c.rats_set_log_level(if (opts.verbose)
        @intCast(c.RATS_LOG_INFO)
    else
        @intCast(c.RATS_LOG_WARN));

    // Every string handed to librats must be NUL-terminated and stay valid until
    // rats_destroy(), which the arena guarantees for the whole run.
    const room_z = try arena.dupeSentinel(u8, opts.room, 0);

    var config: c.rats_config_t = .{
        .protocol = protocol,
        .listen_port = opts.port,
    };
    if (opts.data_dir) |dir| config.data_dir = (try arena.dupeSentinel(u8, dir, 0)).ptr;

    // Received lines are produced on a librats reactor thread and consumed here;
    // the callback must never block, so it only formats and queues. The inbox is
    // set up before the node because it has to outlive it: see the defer order.
    var inbox: Inbox = .{};
    defer inbox.deinit(gpa);
    const ctx = try arena.create(Ctx);
    ctx.* = .{ .gpa = gpa, .io = io, .inbox = &inbox };

    const node = c.rats_create(&config) orelse {
        try out.print("rekarma: rats_create() rejected the configuration\n", .{});
        try out.flush();
        std.process.exit(1);
    };
    // Deferred after the inbox so that it runs before it (defers unwind in
    // reverse): rats_destroy() is what guarantees no callback is still queueing
    // when the inbox it writes to is freed.
    defer c.rats_destroy(node);

    // All of this is before rats_start(): librats refuses to enable a subsystem
    // or take a callback on a running node.
    try check(out, c.rats_enable_pubsub(node), "pubsub");
    try check(out, c.rats_subscribe(node, room_z.ptr, onMessage, ctx), "subscribe");
    try check(out, c.rats_enable_reconnect(node), "reconnect");
    // A dial that discovery asked for but the network refused would otherwise be
    // invisible at the default log level; this is what says "found, not reachable".
    _ = c.rats_on_dial_failed(node, onDialFailed, ctx);
    // Discovery is layer by layer so a run can be pinned to one of them: neither
    // the DHT nor mDNS can be told apart from the other when a message does not
    // arrive, which is exactly the debugging that matters.
    const use_dht = opts.discovery and opts.dht;
    const use_mdns = opts.discovery and opts.mdns;
    if (use_dht) {
        // The DHT discovery key is the room itself, so discovery only ever finds
        // nodes that joined this room.
        try check(out, c.rats_enable_dht(node, 0, room_z.ptr), "dht discovery");
    }
    if (use_mdns) try check(out, c.rats_enable_mdns(node), "mdns discovery");
    if (opts.discovery) try check(out, c.rats_enable_peer_exchange(node), "peer exchange");
    if (opts.nat) {
        // Discovery only hands out the public address it learned, and a node
        // behind a NAT is unreachable there: asking the router for the port and
        // being willing to arrange punches is what turns a discovered peer into
        // a connection. Port mapping is best effort — a router without UPnP is
        // not a reason to refuse to start.
        soft(out, c.rats_enable_port_mapping(node, 1, 1), "port mapping");
        soft(out, c.rats_enable_hole_punch(node, 1), "hole punching");
    }
    if (opts.relay) {
        // The last rung, and the only one that reaches a peer behind carrier-grade
        // NAT: a node connected to both ends carries the bytes. Serving is a
        // separate, explicit choice — it is somebody else's traffic on our uplink.
        soft(out, c.rats_enable_relay(node, @intFromBool(opts.serve_relay)), "relay");
    }

    try check(out, c.rats_start(node), "start");

    for (opts.peers.items) |peer| {
        const host_z = try arena.dupeSentinel(u8, peer.host, 0);
        try check(out, c.rats_connect(node, host_z.ptr, peer.port), "connect");
        // Reconnect only ever redials addresses somebody handed it.
        _ = c.rats_add_reconnect(node, host_z.ptr, peer.port);
    }

    try out.print("room     {s}\n", .{opts.room});
    // A sender never opens the file, and naming one would suggest it recorded
    // something: what it publishes is in the room, not in a file here.
    if (send_only) {
        try out.print("log      none (a send only publishes; --stay records)\n", .{});
    } else {
        try out.print("log      {s} (last {d} messages)\n", .{ log_path, opts.count });
    }
    try out.print("node     {s} on port {d}\n", .{
        std.mem.span(c.rats_local_id(node)), c.rats_listen_port(node),
    });
    if (!opts.discovery) {
        try out.print("         discovery off: only --connect peers are dialed\n", .{});
    } else if (!use_dht or !use_mdns) {
        try out.print("         discovery: {s}{s}{s}\n", .{
            if (use_dht) "dht" else "",
            if (use_dht and use_mdns) "+" else "",
            if (use_mdns) "mdns" else "",
        });
    }
    try out.flush();

    if (opts.message.items.len != 0) {
        const text = try std.mem.join(arena, " ", opts.message.items);
        // Nobody can be found over the DHT in the first seconds — the bootstrap
        // and one announce/search round take about 40 s — so the wait a sender
        // gets depends on whether the DHT is one of the ways it can find peers.
        const wait = opts.wait_seconds orelse
            if (use_dht) publish_wait_with_dht else publish_wait_without_dht;
        try publish(io, node, room_z, text, wait, out);

        // A send is over when the message is out: drain the reactor, then exit
        // through the same unwind a stopped node takes (rats_destroy() first).
        if (send_only) {
            Io.sleep(io, .fromMilliseconds(send_drain_ms), .awake) catch {};
            return;
        }
    }

    try out.print("listening in {s} — Ctrl-C to stop\n", .{opts.room});
    try out.flush();

    while (!stop.load(.acquire)) {
        var batch = inbox.drain();
        defer batch.deinit(gpa);
        for (batch.items) |item| {
            switch (item) {
                // A notice is about the node, not something the room carried: say
                // it, but keep it out of the room's file.
                .notice => |text| {
                    defer gpa.free(text);
                    try out.print("{s}\n", .{text});
                    try out.flush();
                },
                .message => |line| {
                    defer gpa.free(line);
                    log.append(io, line) catch |err| {
                        try out.print("rekarma: cannot write {s}: {s}\n", .{ log_path, @errorName(err) });
                        continue;
                    };
                    try out.print("{s}\n", .{line});
                    try out.flush();
                },
            }
        }
        // Nothing arrived: idle briefly rather than spin on the inbox mutex.
        if (batch.items.len == 0) Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }

    try out.print("\nstopped\n", .{});
    try out.flush();
}

/// Publish one message into the room, after waiting for a peer: pushed into a
/// mesh with nobody in it the bytes go nowhere, which looks exactly like a
/// broken room, and the sender cannot tell the two apart. `wait_seconds` is how
/// long that wait may be — long enough for the DHT to have found someone, or
/// short when mDNS/--connect answer at once.
fn publish(io: Io, node: c.rats_t, room_z: [:0]const u8, text: []const u8, wait_seconds: u32, out: *Io.Writer) !void {
    var tenths: u32 = 0;
    while (c.rats_peer_count(node) == 0 and tenths < wait_seconds * 10) : (tenths += 1) {
        // A silent 90 s looks like a hang, so say what is being waited for.
        if (tenths % 50 == 0) {
            try out.print("waiting for a peer in {s} ({d}s{s})\n", .{
                room_z,
                tenths / 10,
                if (tenths == 0) " — the DHT announce/search round takes ~40s" else "",
            });
            try out.flush();
        }
        Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    if (c.rats_peer_count(node) == 0) {
        try out.print("nobody else is in {s}; publishing into it anyway\n", .{room_z});
        try out.flush();
    }
    try check(out, c.rats_publish(node, room_z.ptr, text.ptr, text.len), "publish");
    try out.print("published to {s}: {s}\n", .{ room_z, text });
    try out.flush();
}

/// `rekarma --daemon`: the recording node, started in the background.
///
/// The parent reports where the daemon went and leaves; the child detaches from
/// the terminal, points its standard streams at a log file and records the room
/// until it is signalled. Nothing here forks a second time: one fork plus
/// setsid() is a session with no controlling terminal, which is all a daemon
/// needs (a closing terminal no longer sends it SIGHUP).
fn daemonize(arena: std.mem.Allocator, io: Io, out: *Io.Writer, log_path: []const u8, opts: Options) !void {
    // A daemon prints where nobody is looking, so its output needs a file; both
    // it and the pid file default to sitting next to the room's own log, which
    // makes one run leave one recognizable set of files.
    const log_file = if (opts.log) |template|
        try roomFilePath(arena, template, opts.room)
    else
        try std.fmt.allocPrint(arena, "{s}.log", .{log_path});
    const pid_file = if (opts.pid) |template|
        try roomFilePath(arena, template, opts.room)
    else
        try std.fmt.allocPrint(arena, "{s}.pid", .{log_path});

    const log_z = try arena.dupeSentinel(u8, log_file, 0);

    // fork() is safe exactly here and nowhere later: no librats node exists yet,
    // so this is still the one thread the child inherits — after rats_create()
    // the reactor threads a fork drops would be the node's.
    const child = std.c.fork();
    if (child < 0) {
        try out.print("rekarma: fork failed, the daemon was not started\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    if (child > 0) {
        // The parent has nothing left to do but say where the daemon went. _exit
        // and not exit: the child owns a copy of this memory now, and this
        // process must not run the IO teardown of a run it is no longer part of.
        try out.print("rekarma: daemon started, pid {d}\n", .{child});
        try out.print("         log      {s}\n", .{log_file});
        try out.print("         pid file {s}\n", .{pid_file});
        try out.print("         stop     kill $(cat {s})\n", .{pid_file});
        try out.flush();
        std.c._exit(0);
    }

    // The fork left the child in the shell's process group and therefore not a
    // group leader, which is the condition setsid() needs to succeed.
    _ = std.c.setsid();

    // Append, and only append: a restarted daemon continues the log of the run
    // that ended instead of erasing the failure that ended it.
    const flags: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const log_fd = std.c.open(log_z.ptr, flags, @as(std.c.mode_t, 0o644));
    if (log_fd < 0) {
        try out.print("rekarma: cannot write the daemon's log {s}\n", .{log_file});
        try out.flush();
        std.process.exit(1);
    }
    // stdout *and* stderr: librats' own errors go to stderr, and a daemon that
    // dropped them would have nowhere at all to report a failure.
    _ = std.c.dup2(log_fd, 1);
    _ = std.c.dup2(log_fd, 2);
    if (log_fd > 2) _ = std.c.close(log_fd);

    // Nothing ever reads a detached process's stdin, and a terminal that is gone
    // is not a useful thing for it to hold open.
    const dev_null = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    if (dev_null >= 0) {
        _ = std.c.dup2(dev_null, 0);
        if (dev_null > 2) _ = std.c.close(dev_null);
    }

    // The daemon writes its own pid: it is the only process that knows the pid it
    // kept, and that file is how it is found again for a kill. The parent has
    // already printed the same number, so an unwritable file is not fatal.
    const pid = std.c.getpid();
    var pid_buf: [32]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buf, "{d}\n", .{pid}) catch unreachable;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = pid_file, .data = pid_text }) catch |err| {
        try out.print("rekarma: cannot write the pid file {s}: {s}\n", .{ pid_file, @errorName(err) });
    };

    // The first line of the log: what pid this run kept, and where its output is
    // — the parent says the same to the terminal it was started from.
    try out.print("daemon   pid {d}, log {s}\n", .{ pid, log_file });
    try out.flush();
}

/// A fallible librats call answers RATS_OK (0) on success; anything else is a
/// configuration mistake no retry can fix.
fn check(out: *Io.Writer, err: c.rats_error_t, what: []const u8) !void {
    if (err == 0) return;
    try out.print("rekarma: {s} failed: {s}\n", .{ what, std.mem.span(c.rats_error_str(err)) });
    try out.flush();
    std.process.exit(1);
}

/// Same, for a subsystem whose absence degrades the node (no port mapping behind
/// a router without UPnP) instead of making it wrong.
fn soft(out: *Io.Writer, err: c.rats_error_t, what: []const u8) void {
    if (err == 0) return;
    out.print("rekarma: {s} unavailable: {s}\n", .{ what, std.mem.span(c.rats_error_str(err)) }) catch {};
    out.flush() catch {};
}

fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    stop.store(true, .release);
}

/// The room's file: --file may name the room, so one file per room needs no
/// wrapper script ("logs/{room}.txt"). Without the placeholder the path is used
/// exactly as given, which is what the all.txt default relies on.
fn roomFilePath(gpa: std.mem.Allocator, template: []const u8, room: []const u8) ![]u8 {
    const placeholder = "{room}";
    if (std.mem.indexOf(u8, template, placeholder) == null) return gpa.dupe(u8, template);

    const path = try gpa.alloc(u8, std.mem.replacementSize(u8, template, placeholder, room));
    _ = std.mem.replace(u8, template, placeholder, room, path);
    return path;
}

/// What the reactor thread hands the main loop: a room message (logged and
/// printed) or a notice about the node itself (printed only — it is not
/// something the room said).
const Item = union(enum) {
    message: []u8,
    notice: []u8,
};

/// Lines produced on a librats reactor thread and consumed on the main loop: a
/// room message can arrive at any point in this process's work, so the callback
/// never touches the file itself.
const Inbox = struct {
    lock: room_log.Spinlock = .{},
    items: std.ArrayList(Item) = .empty,

    fn push(self: *Inbox, gpa: std.mem.Allocator, item: Item) void {
        self.lock.lock();
        defer self.lock.unlock();
        // Running out of memory loses one message; it must not lose the callback.
        self.items.append(gpa, item) catch switch (item) {
            .message, .notice => |text| gpa.free(text),
        };
    }

    /// Everything queued so far, as a list the caller owns and frees.
    fn drain(self: *Inbox) std.ArrayList(Item) {
        self.lock.lock();
        defer self.lock.unlock();
        const taken = self.items;
        self.items = .empty;
        return taken;
    }

    fn deinit(self: *Inbox, gpa: std.mem.Allocator) void {
        for (self.items.items) |item| switch (item) {
            .message, .notice => |text| gpa.free(text),
        };
        self.items.deinit(gpa);
    }
};

/// The message callback's own state: it never sees the node or the log.
const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    inbox: *Inbox,
};

/// Called on a librats reactor thread for every message published to the room,
/// by anyone in it. Keep it short: format a line and queue it.
fn onMessage(user: ?*anyopaque, peer_id: [*c]const u8, topic: [*c]const u8, data: ?*const anyopaque, len: usize) callconv(.c) void {
    _ = topic; // there is one room per run, so the file it lands in already says it
    const ctx: *Ctx = @ptrCast(@alignCast(user orelse return));
    const from = std.mem.span(peer_id);
    const payload: []const u8 = if (data) |bytes| @as([*]const u8, @ptrCast(bytes))[0..len] else &.{};
    const line = formatLine(ctx.gpa, ctx.io, from, payload) catch return;
    ctx.inbox.push(ctx.gpa, .{ .message = line });
}

/// A peer that discovery found but the transports could not reach — the usual
/// reason a room looks silent over the DHT and fine over mDNS. Nothing in the
/// default log level says this, so say it.
fn onDialFailed(user: ?*anyopaque, address: [*c]const u8) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user orelse return));
    const text = std.fmt.allocPrint(
        ctx.gpa,
        "no route to {s}: found in this room, not reachable (NAT? try --no-nat, or --connect)",
        .{std.mem.span(address)},
    ) catch return;
    ctx.inbox.push(ctx.gpa, .{ .notice = text });
}

/// "<stamp> <peer> <message>", one line per message: the log stays greppable and
/// its tail stays readable. A newline inside a message would split it across two
/// lines and silently inflate the count, so it becomes a space.
fn formatLine(gpa: std.mem.Allocator, io: Io, peer_id: []const u8, message: []const u8) ![]u8 {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(gpa);
    for (message) |byte| try clean.append(gpa, switch (byte) {
        '\n', '\r' => ' ',
        else => byte,
    });

    // The peer id is 64 hex characters and the whole thing is noise in a log
    // line; its first 12 still tell two senders apart.
    const peer = peer_id[0..@min(peer_id.len, 12)];
    return std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ isoUtc(io), peer, clean.items });
}

/// "2026-10-16T13:24:05Z": fixed width and UTC, so a log file sorts by time as
/// plain text and means the same thing on any host.
fn isoUtc(io: Io) [20]u8 {
    const secs: u64 = @intCast(@max(Io.Timestamp.now(io, .real).toSeconds(), 0));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    var stamp: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&stamp, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch return "0000-00-00T00:00:00Z".*;
    return stamp;
}

fn parseArgs(gpa: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var opts: Options = .{};
    var reader: Reader = .{ .args = args };

    parse: while (reader.next()) |argv| {
        // The message to publish is whatever is left over, option-free.
        if (argv.len == 0 or argv[0] != '-') {
            try opts.message.append(gpa, argv);
            continue;
        }
        const attached = std.mem.indexOfScalar(u8, argv, '=');
        const name = if (attached) |at| argv[0..at] else argv;

        if (std.mem.eql(u8, name, "--")) {
            while (reader.next()) |rest| try opts.message.append(gpa, rest);
            break :parse;
        } else if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, name, "--version")) {
            opts.version = true;
        } else if (std.mem.eql(u8, name, "-v") or std.mem.eql(u8, name, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, name, "--show")) {
            opts.show = true;
        } else if (std.mem.eql(u8, name, "--daemon")) {
            opts.daemon = true;
        } else if (std.mem.eql(u8, name, "--stay")) {
            opts.stay = true;
        } else if (std.mem.eql(u8, name, "--log")) {
            opts.log = reader.value(attached) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} needs a file name", .{name});
                break :parse;
            };
        } else if (std.mem.eql(u8, name, "--pid")) {
            opts.pid = reader.value(attached) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} needs a file name", .{name});
                break :parse;
            };
        } else if (std.mem.eql(u8, name, "--no-discovery")) {
            opts.discovery = false;
        } else if (std.mem.eql(u8, name, "--no-dht")) {
            opts.dht = false;
        } else if (std.mem.eql(u8, name, "--no-mdns")) {
            opts.mdns = false;
        } else if (std.mem.eql(u8, name, "--no-nat")) {
            opts.nat = false;
        } else if (std.mem.eql(u8, name, "--no-relay")) {
            opts.relay = false;
        } else if (std.mem.eql(u8, name, "--serve-relay")) {
            opts.relay = true;
            opts.serve_relay = true;
        } else if (std.mem.eql(u8, name, "-w") or std.mem.eql(u8, name, "--wait")) {
            const value = reader.value(attached) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} needs a number of seconds", .{name});
                break :parse;
            };
            opts.wait_seconds = std.fmt.parseInt(u32, value, 10) catch {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} is not a number of seconds", .{value});
                break :parse;
            };
        } else if (std.mem.eql(u8, name, "-r") or std.mem.eql(u8, name, "--room")) {
            opts.room = reader.value(attached) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} needs a room name", .{name});
                break :parse;
            };
        } else if (std.mem.eql(u8, name, "-f") or std.mem.eql(u8, name, "--file")) {
            opts.file = reader.value(attached) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} needs a file name", .{name});
                break :parse;
            };
        } else if (std.mem.eql(u8, name, "-d") or std.mem.eql(u8, name, "--data-dir")) {
            opts.data_dir = reader.value(attached) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} needs a directory", .{name});
                break :parse;
            };
        } else if (std.mem.eql(u8, name, "-n") or std.mem.eql(u8, name, "--count")) {
            const value = reader.value(attached) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} needs a message count", .{name});
                break :parse;
            };
            opts.count = std.fmt.parseInt(usize, value, 10) catch {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} is not a message count", .{value});
                break :parse;
            };
            if (opts.count == 0) {
                opts.problem = "a count of 0 would record nothing";
                break :parse;
            }
        } else if (std.mem.eql(u8, name, "-p") or std.mem.eql(u8, name, "--port")) {
            const value = reader.value(attached) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} needs a port", .{name});
                break :parse;
            };
            opts.port = std.fmt.parseInt(u16, value, 10) catch {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} is not a port number", .{value});
                break :parse;
            };
        } else if (std.mem.eql(u8, name, "-c") or std.mem.eql(u8, name, "--connect")) {
            const value = reader.value(attached) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} needs host:port", .{name});
                break :parse;
            };
            const peer = splitPeerAddress(value) orelse {
                opts.problem = try std.fmt.allocPrint(gpa, "{s} is not host:port", .{value});
                break :parse;
            };
            try opts.peers.append(gpa, peer);
        } else {
            opts.problem = try std.fmt.allocPrint(gpa, "unknown option {s}", .{name});
            break :parse;
        }
    }

    if (opts.problem == null) {
        // An empty value is only ever a typing mistake ("--room="), and librats
        // would take it as a topic.
        if (opts.room.len == 0) opts.problem = "the room name cannot be empty";
        if (opts.file.len == 0) opts.problem = "the file name cannot be empty";
        // --daemon records and stays up: a message given with it would never be
        // published, and --show prints and returns, which is the opposite.
        if (opts.daemon and opts.message.items.len != 0) {
            opts.problem = "--daemon records the room; a message given with it would never be published";
        }
        if (opts.daemon and opts.show) {
            opts.problem = "--daemon and --show ask for opposite things: one stays up, the other prints and exits";
        }
    }

    return opts;
}

/// "127.0.0.1:4001" or "[::1]:4001" — the bracketed form is how an IPv6 address
/// stays distinguishable from the port separator.
fn splitPeerAddress(address: []const u8) ?Peer {
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return null;
    var host = address[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    if (host.len == 0) return null;
    return .{
        .host = host,
        .port = std.fmt.parseInt(u16, address[colon + 1 ..], 10) catch return null,
    };
}

/// Reads the command line, pulling an option's value from the next argument when
/// it was not attached with '='.
const Reader = struct {
    args: []const [:0]const u8,
    i: usize = 1,
    /// What next() returned last, so value() can slice an attached '=' out of it.
    current: []const u8 = "",

    fn next(self: *Reader) ?[]const u8 {
        if (self.i >= self.args.len) return null;
        self.current = self.args[self.i];
        self.i += 1;
        return self.current;
    }

    fn value(self: *Reader, attached: ?usize) ?[]const u8 {
        if (attached) |at| return self.current[at + 1 ..];
        return self.next();
    }
};

const Peer = struct { host: []const u8, port: u16 };

const Options = struct {
    room: []const u8 = default_room,
    file: []const u8 = default_file,
    count: usize = default_count,
    port: u16 = 0,
    data_dir: ?[]const u8 = null,
    peers: std.ArrayList(Peer) = .empty,
    message: std.ArrayList([]const u8) = .empty,
    discovery: bool = true,
    dht: bool = true,
    mdns: bool = true,
    /// Ask the router for the listen port and allow hole punching. Without it a
    /// node behind a NAT is discoverable but unreachable, which is what makes the
    /// DHT look broken next to mDNS.
    nat: bool = true,
    /// Accept being routed through another peer when no direct path exists — the
    /// only way two carriers-grade-NAT'd nodes ever meet.
    relay: bool = true,
    /// Also carry other peers' connections on this node's uplink.
    serve_relay: bool = false,
    /// Seconds to wait for a peer before publishing anyway; null = pick by
    /// whether the DHT is one of the ways peers can be found.
    wait_seconds: ?u32 = null,
    verbose: bool = false,
    show: bool = false,
    help: bool = false,
    /// Print the versions of this program and of the librats it is linked
    /// against, then exit.
    version: bool = false,
    /// Record in the background: fork into a session of its own and put the
    /// standard streams in a log file.
    daemon: bool = false,
    /// Keep recording after publishing a command-line message instead of exiting
    /// once it is out.
    stay: bool = false,
    /// Where a daemon's stdout/stderr go; null = next to the room's file. {room}
    /// is replaced by the room name, as in --file.
    log: ?[]const u8 = null,
    /// Where a daemon records its pid; null = next to the room's file.
    pid: ?[]const u8 = null,
    /// Set instead of the options when the command line does not parse.
    problem: ?[]const u8 = null,
};

fn printUsage(out: *Io.Writer) !void {
    try out.print(
        \\ReKarma - distributed recommendation system
        \\
        \\Joins one pubsub room over librats and records the last messages it
        \\carries in that room's file.
        \\
        \\Usage: rekarma [options] [message]
        \\
        \\A message on the command line is published into the room (after waiting
        \\briefly for a peer) and the program exits once it is out; --stay keeps
        \\recording afterwards, as it used to.
        \\
        \\--daemon records the room in the background until it is signalled:
        \\  kill $(cat <pid file>)
        \\
        \\Options:
        \\  -r, --room <name>      pubsub room to join            [{s}]
        \\  -f, --file <path>      file that room is recorded in   [{s}]
        \\                         {{{{room}}}} in the path is replaced by the room name
        \\  -n, --count <n>        newest messages kept and shown  [{d}]
        \\  -p, --port <port>      listen port, 0 = ephemeral      [0]
        \\  -d, --data-dir <dir>   identity and state directory    [none]
        \\  -c, --connect <h:p>    dial a peer, repeatable         [none]
        \\  -w, --wait <sec>       wait for a peer before publishing [90, or 5 without dht]
        \\      --daemon           record in the background, detached from this terminal
        \\      --stay             keep recording after publishing, do not exit
        \\      --log <path>       daemon's stdout and stderr       [<file>.log]
        \\      --pid <path>       daemon's pid file                [<file>.pid]
        \\      --no-discovery     no DHT, mDNS or peer exchange, only --connect
        \\      --no-dht           no DHT announce/search
        \\      --no-mdns          no local-network discovery
        \\      --no-nat           no UPnP port mapping or hole punching
        \\      --no-relay         never route through another peer
        \\      --serve-relay      also carry other peers' traffic (uses this uplink)
        \\      --show             print the room's last messages and exit
        \\  -v, --verbose          show librats' own INFO logs on stdout
        \\      --version          print rekarma's and librats' versions and exit
        \\  -h, --help             this help
        \\
        \\Examples:
        \\  rekarma                          record the default room in the foreground
        \\  rekarma "hello peers"            publish to the room, then exit
        \\  rekarma --stay "hello peers"     publish, then keep recording
        \\  rekarma --daemon                 record the default room in the background
        \\  rekarma --daemon -r news -f "logs/{{room}}.txt" -n 50
        \\  rekarma --show                   print all.txt's last 1000 messages
        \\
    , .{ default_room, default_file, default_count });
}

/// `--version`: what this program is and what it is linked against, one fact per
/// line so a script can grep it. Every other option answers "how do I run this";
/// this one answers "which build is this" and touches neither the network nor
/// the room's file.
fn printVersions(out: *Io.Writer) !void {
    try out.print("rekarma {s}\n", .{version});
    try printLibratsVersion(out);
}

/// The librats half of the version answer. It is read out of the linked library
/// itself rather than from a constant in this project: the point of the question
/// is which archive is actually in the binary, and a constant could only ever
/// agree with the build.zig.zon pin, not with the library.
fn printLibratsVersion(out: *Io.Writer) !void {
    var major: c_int = 0;
    var minor: c_int = 0;
    var patch: c_int = 0;
    var build: c_int = 0;
    c.rats_version(&major, &minor, &patch, &build);

    try out.print("librats {s} (major={d} minor={d} patch={d} build={d})\n", .{
        std.mem.span(c.rats_version_string()), major, minor, patch, build,
    });
    try out.print("librats abi 0x{x:0>6}, git {s}\n", .{
        c.rats_abi(), std.mem.span(c.rats_git_describe()),
    });
}

fn printBanner(out: *Io.Writer) !void {
    try out.print("ReKarma - distributed recommendation system\n", .{});
    try printLibratsVersion(out);
    // Flushed here, not with the rest: everything after this point can block on
    // the network (DHT bootstrap), and a banner still in the buffer would make a
    // slow start look like a hang.
    try out.flush();
}
