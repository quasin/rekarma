const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to the portable x86_64 baseline instead of the host CPU: Zig's
    // default is `native`, which bakes in AVX-512 and friends and dies with
    // SIGILL on any older machine the binary is copied to. Pass `-Dcpu=native`
    // for a machine-local binary.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Both C/C++ dependencies are vendored per target triple, because a static
    // archive only links into a binary of the architecture it was compiled for:
    //   vendor/librats/<triple>/{include,librats.a}   the engine
    //   vendor/fuse3/<triple>/{include,libfuse3.a}    the mount
    // scripts/fetch-librats.sh and scripts/fetch-fuse3.sh write these; nothing
    // under vendor/ is committed.
    const triple = tripleName(b, target.result);

    // Fail with the fix instead of a raw linker error when a target was never
    // vendored (an empty archive path would otherwise reach the linker).
    for ([_][2][]const u8{
        .{ "librats", "librats.a" },
        .{ "fuse3", "libfuse3.a" },
    }) |dep| {
        const archive = b.fmt("vendor/{s}/{s}/{s}", .{ dep[0], triple, dep[1] });
        std.Io.Dir.cwd().access(b.graph.io, archive, .{}) catch {
            std.debug.panic(
                "{s} is not vendored for {s} — run `bash scripts/fetch-{s}.sh {s}`, then rebuild",
                .{ dep[1], triple, dep[0], triple },
            );
        };
    }

    const librats_include = b.path(b.fmt("vendor/librats/{s}/include", .{triple}));
    const librats_archive = b.path(b.fmt("vendor/librats/{s}/librats.a", .{triple}));
    const fuse_include = b.path(b.fmt("vendor/fuse3/{s}/include", .{triple}));
    const fuse_archive = b.path(b.fmt("vendor/fuse3/{s}/libfuse3.a", .{triple}));

    // The version the binary reports (--version, the banner) is the one
    // build.zig.zon declares: injecting it here keeps a single place to bump
    // instead of a constant in src/ that drifts from the manifest.
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", @import("build.zig.zon").version);

    // librats exposes a C ABI at librats/bindings/rats.h; the headers around it
    // are C++. Zig 0.17 has no inline @cImport, so they are translated into a
    // module from src/c.h and imported as `c`.
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
            .imports = &.{
                .{ .name = "build_options", .module = opts.createModule() },
                .{ .name = "c", .module = translate_c.createModule() },
            },
        }),
    });

    wireSources(b, exe, librats_include, fuse_include);
    exe.root_module.addObjectFile(librats_archive);
    exe.root_module.addObjectFile(fuse_archive);

    b.installArtifact(exe);

    // `zig build dist` builds all three published targets into
    // zig-out/<triple>/rekarma in ReleaseSafe (panic messages kept, undefined
    // behaviour not exploited). Each is a separate executable, because a build
    // graph artifact has exactly one target.
    const dist_targets = [_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu", "riscv64-linux-gnu" };
    const dist_step = b.step("dist", "Build rekarma for linux x86_64/aarch64/riscv64");
    for (dist_targets) |dt| {
        const dt_target = b.resolveTargetQuery(.{ .cpu_arch = dtArch(dt), .os_tag = .linux, .abi = .gnu });
        const dt_librats_include = b.path(b.fmt("vendor/librats/{s}/include", .{dt}));
        const dt_fuse_include = b.path(b.fmt("vendor/fuse3/{s}/include", .{dt}));

        const dt_translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/c.h"),
            .target = dt_target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        });
        dt_translate_c.addIncludePath(dt_librats_include);

        const dt_exe = b.addExecutable(.{
            .name = "rekarma",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = dt_target,
                .optimize = .ReleaseSafe,
                .strip = true,
                .imports = &.{
                    .{ .name = "build_options", .module = opts.createModule() },
                    .{ .name = "c", .module = dt_translate_c.createModule() },
                },
            }),
        });
        wireSources(b, dt_exe, dt_librats_include, dt_fuse_include);
        dt_exe.root_module.addObjectFile(b.path(b.fmt("vendor/librats/{s}/librats.a", .{dt})));
        dt_exe.root_module.addObjectFile(b.path(b.fmt("vendor/fuse3/{s}/libfuse3.a", .{dt})));

        const install = b.addInstallArtifact(dt_exe, .{
            .dest_dir = .{ .override = .{ .custom = dt } },
        });
        dist_step.dependOn(&install.step);
    }

    // The room log is pure Zig — no librats, no C module — so its unit tests need
    // nothing but the compiler and run in a watertight module of their own.
    const log_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/room_log.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The torrent tree is the same kind of code: pure Zig, no engine and no
    // FUSE, so it is tested on its own — the path/offset mapping is the one
    // place a mounted release could hand out the wrong bytes.
    const tree_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/magnet_tree.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The tracker announce is a URL builder and a bencode reader — pure, and the
    // part of the https path that can be tested without a network.
    const tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tracker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(log_tests).step);
    test_step.dependOn(&b.addRunArtifact(tree_tests).step);
    test_step.dependOn(&b.addRunArtifact(tracker_tests).step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
}

/// Everything both the host and each dist executable need: the C++ shim that
/// reaches into librats' bittorrent engine, and the C glue that owns libfuse3's
/// layout-heavy types.
fn wireSources(b: *std.Build, exe: *std.Build.Step.Compile, librats_include: std.Build.LazyPath, fuse_include: std.Build.LazyPath) void {
    const m = exe.root_module;
    m.link_libc = true;
    // Both archives are compiled by `zig c++`/`zig cc`, i.e. against Zig's
    // bundled libc++ — the same C++ runtime this link pulls in. That is what
    // makes them portable across targets instead of tied to a system libstdc++
    // ABI.
    m.link_libcpp = true;
    m.addIncludePath(librats_include);
    m.addIncludePath(fuse_include);

    // The bittorrent half of --magnet is C++ (librats exposes no C API for
    // metadata, piece priorities or piece reads). It is compiled by Zig's C++
    // driver for the same target and links against the same archive, so the
    // `private`-spelled-public member layout it depends on is the one the
    // library was built from.
    m.addCSourceFile(.{
        .file = b.path("src/magnet_shim.cpp"),
        .flags = &.{"-std=c++17"},
    });

    // libfuse3 through one small C file: struct fuse_operations and struct stat
    // are layout-heavy and stay in C, while the filesystem itself is Zig.
    m.addCSourceFile(.{
        .file = b.path("src/fuse_glue.c"),
        .flags = &.{"-std=c11"},
    });
}

fn tripleName(b: *std.Build, r: std.Target) []const u8 {
    return b.fmt("{s}-{s}-{s}", .{
        @tagName(r.cpu.arch),
        @tagName(r.os.tag),
        @tagName(r.abi),
    });
}

fn dtArch(triple: []const u8) std.Target.Cpu.Arch {
    if (std.mem.startsWith(u8, triple, "aarch64")) return .aarch64;
    if (std.mem.startsWith(u8, triple, "riscv64")) return .riscv64;
    return .x86_64;
}
