//! Tracker announces the engine cannot make itself.
//!
//! librats has no TLS, so it refuses every `https://` tracker outright and a
//! *private* tracker release — whose swarm is not on the DHT — then has no peer
//! source at all: the mount appears (the metadata is in the .torrent) but every
//! read waits for pieces no peer will send. Many trackers also answer plain
//! HTTP with a 301 to https.
//!
//! So the announce happens here instead: std.http.Client does the TLS, and the
//! peers it returns are handed to the engine, which knows what to do with them.
//! One announce at start is enough to open the swarm; librats' own peer exchange
//! and DHT take over from there.
//!
//! Only what an announce needs is implemented: a GET with the standard tracker
//! parameters, and enough bencode to read `failure reason`, `peers` and
//! `peers6`. Compact IPv4 peers are parsed; IPv6 peers are reported and skipped
//! (a v6 peer list on a host without v6 routing is not worth dialling).

const std = @import("std");
const Io = std.Io;

/// The most peers one announce is taken to carry; a tracker that sends more is
/// cut off at this, because the engine is looking for a head start, not a census.
pub const max_peers = 200;

pub const Peer = struct {
    host: [16]u8,
    host_len: u8,
    port: u16,

    pub fn hostSlice(self: *const Peer) []const u8 {
        return self.host[0..self.host_len];
    }
};

pub const Announce = struct {
    peers: [max_peers]Peer = undefined,
    peer_count: usize = 0,
    /// The tracker's own refusal ("torrent not registered", "invalid passkey"),
    /// which is the difference between a wrong link and an unreachable tracker.
    /// Copied, not borrowed: it comes out of a response buffer that is freed as
    /// soon as the announce returns.
    failure_buf: [160]u8 = undefined,
    failure_len: usize = 0,
    /// How many IPv6 peers were dropped unparsed.
    skipped_v6: usize = 0,

    pub fn failure(self: *const Announce) []const u8 {
        return self.failure_buf[0..self.failure_len];
    }
};

pub const Params = struct {
    /// Raw 20-byte info-hash and peer id: the tracker wants them percent-encoded.
    info_hash: [20]u8,
    peer_id: [20]u8,
    port: u16,
    /// Bytes still missing; the tracker uses it to tell seeds from leechers.
    left: u64,
    /// `started` when the mount opens, `stopped` when it goes away: a tracker
    /// that is told nothing keeps the peer in its list until the interval runs
    /// out, and a private one then refuses the next announce as a second client.
    event: Event = .started,

    pub const Event = enum { started, stopped };
};

/// Announce to @p url and return the peers it lists. Errors are I/O or TLS
/// failures — a tracker that answers with a refusal is still a successful call,
/// with `failure` filled in.
pub fn announce(allocator: std.mem.Allocator, io: Io, url: []const u8, params: Params) !Announce {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const request_url = try buildUrl(allocator, url, params);
    defer allocator.free(request_url);

    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = request_url },
        .method = .GET,
        .response_writer = &body.writer,
        // A tracker that redirects to https is the common case, and fetch
        // follows redirects itself.
        .extra_headers = &.{.{ .name = "user-agent", .value = "rekarma" }},
    });
    if (@backingInt(result.status) != 200) return error.TrackerHttpStatus;

    var out: Announce = .{};
    try parseResponse(body.written(), &out);
    return out;
}

/// The tracker's parameters, in the order trackers expect them. The two binary
/// fields are percent-encoded byte by byte; everything else is decimal.
fn buildUrl(allocator: std.mem.Allocator, url: []const u8, params: Params) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, url);
    try out.append(allocator, if (std.mem.indexOfScalar(u8, url, '?') != null) '&' else '?');

    try out.appendSlice(allocator, "info_hash=");
    try appendEncoded(allocator, &out, &params.info_hash);
    try out.appendSlice(allocator, "&peer_id=");
    try appendEncoded(allocator, &out, &params.peer_id);
    try out.print(allocator, "&port={d}&uploaded=0&downloaded=0&left={d}&compact=1&numwant=50&event={s}", .{
        params.port, params.left, @tagName(params.event),
    });
    return out.toOwnedSlice(allocator);
}

fn appendEncoded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (bytes) |byte| {
        // RFC 3986 unreserved characters stay as they are; everything else is
        // escaped, including the '%' itself. A binary field never contains an
        // unreserved byte by chance that must stay raw — escaping all of them
        // would still be valid, and this is the stricter reading.
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try out.append(allocator, byte);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

/// The parts of a bencoded announce response this program uses: a top-level
/// dictionary whose `failure reason` is a string and whose `peers`/`peers6` are
/// compact strings. A full bencode decoder would be more code than the format
/// needs here.
fn parseResponse(body: []const u8, out: *Announce) !void {
    var pos: usize = 0;
    if (body.len == 0 or body[0] != 'd') return error.NotABencodedDict;
    pos += 1;

    while (pos < body.len and body[pos] != 'e') {
        const key = try readString(body, &pos);
        if (std.mem.eql(u8, key, "failure reason")) {
            const reason = try readString(body, &pos);
            out.failure_len = @min(reason.len, out.failure_buf.len);
            @memcpy(out.failure_buf[0..out.failure_len], reason[0..out.failure_len]);
        } else if (std.mem.eql(u8, key, "peers")) {
            if (body[pos] == 'l') {
                pos += 1;
                while (pos < body.len and body[pos] != 'e') try readPeerDict(body, &pos, out);
                pos += 1;
            } else {
                const compact = try readString(body, &pos);
                try readCompact(compact, out, 4);
            }
        } else if (std.mem.eql(u8, key, "peers6")) {
            const compact = try readString(body, &pos);
            out.skipped_v6 += compact.len / 18;
        } else {
            try skipValue(body, &pos);
        }
    }
}

/// `d2:ip7:1.2.3.44:porti6881ee` — the non-compact peer form, which some
/// trackers still send.
fn readPeerDict(body: []const u8, pos: *usize, out: *Announce) !void {
    if (body[pos.*] != 'd') return error.NotABencodedDict;
    pos.* += 1;
    var host_buf: [16]u8 = undefined;
    var host_len: usize = 0;
    var port: u16 = 0;
    while (pos.* < body.len and body[pos.*] != 'e') {
        const key = try readString(body, pos);
        if (std.mem.eql(u8, key, "ip")) {
            const ip = try readString(body, pos);
            host_len = @min(ip.len, host_buf.len);
            @memcpy(host_buf[0..host_len], ip[0..host_len]);
        } else if (std.mem.eql(u8, key, "port")) {
            // BEP 3 says integer, but trackers in the wild send either form.
            if (body[pos.*] == 'i') {
                const end = std.mem.indexOfScalarPos(u8, body, pos.*, 'e') orelse return error.BencodeTruncated;
                port = std.fmt.parseInt(u16, body[pos.* + 1 .. end], 10) catch 0;
                pos.* = end + 1;
            } else {
                const text = try readString(body, pos);
                port = std.fmt.parseInt(u16, text, 10) catch 0;
            }
        } else {
            try skipValue(body, pos);
        }
    }
    pos.* += 1;
    if (host_len > 0 and port != 0 and out.peer_count < max_peers) {
        out.peers[out.peer_count] = .{ .host = host_buf, .host_len = @intCast(host_len), .port = port };
        out.peer_count += 1;
    }
}

/// Compact peers: 4 bytes of IPv4 and 2 of port, big-endian, one after another.
fn readCompact(compact: []const u8, out: *Announce, address_len: usize) !void {
    var i: usize = 0;
    while (i + address_len + 2 <= compact.len and out.peer_count < max_peers) : (i += address_len + 2) {
        const ip = compact[i .. i + address_len];
        const port = (@as(u16, compact[i + address_len]) << 8) | compact[i + address_len + 1];
        if (port == 0) continue;
        var text_buf: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
        out.peers[out.peer_count] = .{
            .host = text_buf,
            .host_len = @intCast(text.len),
            .port = port,
        };
        out.peer_count += 1;
    }
}

fn readString(body: []const u8, pos: *usize) ![]const u8 {
    const colon = std.mem.indexOfScalarPos(u8, body, pos.*, ':') orelse return error.BencodeTruncated;
    const len = std.fmt.parseInt(usize, body[pos.*..colon], 10) catch return error.BencodeTruncated;
    const start = colon + 1;
    if (start + len > body.len) return error.BencodeTruncated;
    pos.* = start + len;
    return body[start .. start + len];
}

fn skipValue(body: []const u8, pos: *usize) !void {
    if (pos.* >= body.len) return error.BencodeTruncated;
    switch (body[pos.*]) {
        'i' => {
            const end = std.mem.indexOfScalarPos(u8, body, pos.*, 'e') orelse return error.BencodeTruncated;
            pos.* = end + 1;
        },
        'l', 'd' => {
            var depth: usize = 0;
            while (pos.* < body.len) {
                switch (body[pos.*]) {
                    'l', 'd' => {
                        depth += 1;
                        pos.* += 1;
                    },
                    'e' => {
                        depth -= 1;
                        pos.* += 1;
                        if (depth == 0) return;
                    },
                    'i' => {
                        const end = std.mem.indexOfScalarPos(u8, body, pos.*, 'e') orelse return error.BencodeTruncated;
                        pos.* = end + 1;
                    },
                    else => _ = try readString(body, pos),
                }
            }
            return error.BencodeTruncated;
        },
        else => _ = try readString(body, pos),
    }
}

const testing = std.testing;

test "tracker: the announce URL carries both binary fields percent-encoded" {
    const a = testing.allocator;
    var info_hash: [20]u8 = @splat(0);
    info_hash[0] = 0xff;
    var peer_id: [20]u8 = @splat('A');
    peer_id[19] = ' ';
    const params: Params = .{
        .info_hash = info_hash,
        .peer_id = peer_id,
        .port = 6881,
        .left = 42,
    };
    const url = try buildUrl(a, "https://tracker.example/announce?passkey=abc", params);
    defer a.free(url);

    try testing.expect(std.mem.startsWith(u8, url, "https://tracker.example/announce?passkey=abc&info_hash=%FF"));
    try testing.expect(std.mem.indexOf(u8, url, "&peer_id=AAAAAAAAAAAAAAAAAAA%20&") != null);
    try testing.expect(std.mem.indexOf(u8, url, "&port=6881&uploaded=0&downloaded=0&left=42&compact=1") != null);
}

test "tracker: compact IPv4 peers and the tracker's own refusal are read" {
    var out: Announce = .{};
    // d8:intervali1800e12:min intervali300e5:peers12:<peer><peer>ee
    const body = "d8:intervali1800e5:peers12:" ++
        "\x1f\x0b\x01\x02\x1a\xe1" ++ // 31.11.1.2:6881
        "\xc0\xa8\x00\x01\x00\x50" ++ // 192.168.0.1:80
        "e";
    try parseResponse(body, &out);
    try testing.expectEqual(@as(usize, 2), out.peer_count);
    try testing.expectEqualStrings("31.11.1.2", out.peers[0].hostSlice());
    try testing.expectEqual(@as(u16, 6881), out.peers[0].port);
    try testing.expectEqualStrings("192.168.0.1", out.peers[1].hostSlice());

    var refused: Announce = .{};
    try parseResponse("d14:failure reason9:not founde", &refused);
    try testing.expectEqualStrings("not found", refused.failure());
    try testing.expectEqual(@as(usize, 0), refused.peer_count);
}

test "tracker: the dictionary peer form and unknown keys still parse" {
    var out: Announce = .{};
    const body = "d5:peersld2:ip8:10.1.2.34:porti51413eee7:privatei1ee";
    try parseResponse(body, &out);
    try testing.expectEqual(@as(usize, 1), out.peer_count);
    try testing.expectEqualStrings("10.1.2.3", out.peers[0].hostSlice());
    try testing.expectEqual(@as(u16, 51413), out.peers[0].port);
}
