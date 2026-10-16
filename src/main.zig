const std = @import("std");
const Io = std.Io;
const c = @import("c");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("ReKarma - distributed recommendation system\n", .{});

    // The version is read out of the linked librats library itself, not from a
    // constant in this project.
    const version_string = std.mem.span(c.rats_version_string());

    var major: c_int = 0;
    var minor: c_int = 0;
    var patch: c_int = 0;
    var build: c_int = 0;
    c.rats_version(&major, &minor, &patch, &build);

    try stdout.print("librats {s} (major={d} minor={d} patch={d} build={d})\n", .{
        version_string, major, minor, patch, build,
    });
    try stdout.print("librats abi 0x{x:0>6}, git {s}\n", .{
        c.rats_abi(), std.mem.span(c.rats_git_describe()),
    });

    try stdout.flush();
}
