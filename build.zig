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

    // Vendored librats 3.0.2, built from source by scripts/fetch-librats.sh with
    // RATS_SEARCH_FEATURES=ON (the prebuilt release archives have the bittorrent
    // stack stubbed out, and --magnet needs it). The script also installs the
    // generated librats/util/features.h next to these headers.
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

    // libfuse3 ships its headers one level down (fuse3/fuse.h) and outside the
    // default include search path; override for a distribution that puts them
    // elsewhere.
    const fuse_include = b.option(
        []const u8,
        "fuse_include",
        "directory holding fuse3/fuse.h",
    ) orelse "/usr/include/fuse3";
    const fuse_lib = b.option([]const u8, "fuse_lib", "libfuse3 link name") orelse "fuse3";

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

    // The version the binary reports (--version, the banner) is the one
    // build.zig.zon declares: injecting it here keeps a single place to bump
    // instead of a constant in src/ that drifts from the manifest. There is no
    // accessor for the root manifest, so it is read and parsed; the fields this
    // binary does not need (name, fingerprint) are ignored.
    const zon_source = std.Io.Dir.cwd().readFileAllocOptions(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .unlimited,
        .of(u8),
        0,
    ) catch |err| std.debug.panic("cannot read build.zig.zon: {s}", .{@errorName(err)});
    var zon_diagnostics: std.zon.parse.Diagnostics = undefined;
    const zon = std.zon.parse.fromSlice(struct { version: []const u8 }, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = zon_source,
        .diagnostics = &zon_diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| {
        zon_diagnostics.log("build.zig.zon");
        std.debug.panic("cannot read the version out of build.zig.zon: {s}", .{@errorName(err)});
    };

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);
    exe.root_module.addImport("build_options", build_options.createModule());

    // librats.a is a static C++ archive built with GCC's libstdc++ (its objects
    // reference the __cxx11 std::string ABI), so it must be linked against the
    // system libstdc++, NOT Zig's bundled libc++.
    exe.root_module.addObjectFile(librats_lib);
    exe.root_module.addIncludePath(librats_include);
    exe.root_module.link_libc = true;
    exe.root_module.addObjectFile(.{ .cwd_relative = stdcpp_path });
    // libstdc++'s unwinder lives in libgcc_s; its objects reference _Unwind_Resume.
    exe.root_module.addObjectFile(.{ .cwd_relative = libgcc_s_path });

    // The bittorrent half of --magnet is C++ (librats exposes no C API for
    // metadata, piece priorities or piece reads) and is compiled by the system
    // g++: Zig's own C++ driver uses the bundled libc++ headers, which do not
    // match the __cxx11 libstdc++ librats.a was built against. The object is
    // linked into the same module, so it sees the same archive.
    const shim = b.addSystemCommand(&.{ "g++", "-std=c++17", "-O2", "-fPIC", "-c" });
    shim.addArg("-I");
    shim.addDirectoryArg(librats_include);
    shim.addFileArg(b.path("src/magnet_shim.cpp"));
    shim.addArg("-o");
    const shim_object = shim.addOutputFileArg("magnet_shim.o");
    exe.root_module.addObjectFile(shim_object);

    // libfuse3 through one small C file: struct fuse_operations and struct stat
    // are layout-heavy and stay in C, while the filesystem itself is Zig.
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/fuse_glue.c"),
        .flags = &.{"-std=c11"},
    });
    exe.root_module.addIncludePath(.{ .cwd_relative = fuse_include });
    exe.root_module.linkSystemLibrary(fuse_lib, .{});

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

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(log_tests).step);
    test_step.dependOn(&b.addRunArtifact(tree_tests).step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
}
