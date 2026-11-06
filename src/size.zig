//! Byte sizes as the cache limit and the read-ahead are given them on the
//! command line: "5G", "512M", "1048576".
//!
//! Suffixes are binary (M = MiB) because everything these numbers are compared
//! against is counted in bytes of pieces, and a "1.5G" that meant 1.4 GiB would
//! only ever be a surprise. Anything that is not a number with an optional
//! K/M/G/T suffix is refused — a typo must not turn into 0, which in both places
//! means "no limit at all".

const std = @import("std");

/// @p text as bytes, or null when it is not a size.
pub fn parse(text: []const u8) ?u64 {
    if (text.len == 0) return null;

    var digits = text.len;
    var scale: u64 = 1;
    switch (std.ascii.toUpper(text[text.len - 1])) {
        'K' => {
            scale = 1 << 10;
            digits -= 1;
        },
        'M' => {
            scale = 1 << 20;
            digits -= 1;
        },
        'G' => {
            scale = 1 << 30;
            digits -= 1;
        },
        'T' => {
            scale = 1 << 40;
            digits -= 1;
        },
        else => {},
    }

    if (digits == 0) return null;
    const value = std.fmt.parseInt(u64, text[0..digits], 10) catch return null;
    return std.math.mul(u64, value, scale) catch null;
}

test "size: plain bytes and every suffix" {
    try std.testing.expectEqual(@as(?u64, 0), parse("0"));
    try std.testing.expectEqual(@as(?u64, 1048576), parse("1048576"));
    try std.testing.expectEqual(@as(?u64, 5 * 1024), parse("5k"));
    try std.testing.expectEqual(@as(?u64, 512 << 20), parse("512M"));
    try std.testing.expectEqual(@as(?u64, 5 << 30), parse("5G"));
    try std.testing.expectEqual(@as(?u64, 2 << 40), parse("2T"));
}

test "size: what is not a size is refused, never 0" {
    try std.testing.expectEqual(@as(?u64, null), parse(""));
    try std.testing.expectEqual(@as(?u64, null), parse("G"));
    try std.testing.expectEqual(@as(?u64, null), parse("5X"));
    try std.testing.expectEqual(@as(?u64, null), parse("5 G"));
    try std.testing.expectEqual(@as(?u64, null), parse("-5"));
    try std.testing.expectEqual(@as(?u64, null), parse("1.5G"));
    // 20 exabytes of GiB overflows; refusing beats wrapping to something small.
    try std.testing.expectEqual(@as(?u64, null), parse("20000000000G"));
}
