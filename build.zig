const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Everything under vendor/ comes from the prebuilt librats release and is not
    // committed: report the fix instead of a raw linker error when it is missing.
    std.Io.Dir.cwd().access(b.graph.io, "vendor/librats/librats.a", .{}) catch {
        std.debug.panic(
            "librats is not vendored yet — run scripts/fetch-librats.sh (install.sh already does), then rebuild",
            .{},
        );
    };

    // Vendored librats 3.0.0 (prebuilt linux-x64 release). Provenance and the
    // hand-written features.h substitution: scripts/librats/features.h.
    const librats_include = b.path("vendor/librats/include");
    const librats_lib = b.path("vendor/librats/librats.a");

    // Path to the system C++ runtime librats.a was built against; override with
    // -Dlibstdcpp=/path/to/libstdc++.so on another distribution.
    const stdcpp_path = b.option(
        []const u8,
        "libstdcpp",
        "path to the system libstdc++.so used to link librats.a",
    ) orelse "/usr/lib/libstdc++.so";

    const libgcc_s_path = b.option(
        []const u8,
        "libgcc_s",
        "path to the system libgcc_s.so used to link librats.a",
    ) orelse "/usr/lib/libgcc_s.so.1";

    // librats ships C++ headers; its public C ABI is librats/bindings/rats.h.
    // Zig 0.17 has no inline @cImport, so the header is translated into a module.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(librats_include);

    const exe = b.addExecutable(.{
        .name = "rekarma",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("c", translate_c.createModule());

    // librats.a is a static C++ archive built with GCC's libstdc++ (its objects
    // reference the __cxx11 std::string ABI), so it must be linked against the
    // system libstdc++, NOT Zig's bundled libc++.
    exe.root_module.addObjectFile(librats_lib);
    exe.root_module.addIncludePath(librats_include);
    exe.root_module.link_libc = true;
    exe.root_module.addObjectFile(.{ .cwd_relative = stdcpp_path });
    // libstdc++'s unwinder lives in libgcc_s; its objects reference _Unwind_Resume.
    exe.root_module.addObjectFile(.{ .cwd_relative = libgcc_s_path });

    b.installArtifact(exe);

    // The room log is pure Zig — no librats, no C module — so its unit tests need
    // nothing but the compiler and run in a watertight module of their own.
    const log_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/room_log.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(log_tests).step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
}
