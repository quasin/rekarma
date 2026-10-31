#!/usr/bin/env bash
# Build libfuse3 from source for each target and vendor the result into
# vendor/fuse3/<arch>-<os>-<abi>/ (include/ + libfuse3.a).
#
# librats is not the only per-target dependency: rekarma mounts through libfuse3,
# and a static library of one architecture cannot be linked into another's
# binary. The host's system libfuse3 is x86_64 only, so the same fetch that
# vendors librats vendors fuse too, and `zig build dist` can then produce all
# three binaries from one tree.
#
# libfuse3 is built with the same rule as librats: Zig's own C compiler
# (`zig cc -target <triple>`), static, and cross-linked against Zig's glibc. The
# result needs no libfuse3.so at runtime — only the fusermount3 helper the
# library execs, which is provided by the target system.
#
# meson and ninja are required for this step (libfuse builds with meson, there is
# no CMake or plain makefile). `pip install --user meson ninja` is enough.
set -euo pipefail

FUSE_VERSION="3.18.3"
URL="https://github.com/libfuse/libfuse/releases/download/fuse-${FUSE_VERSION}/fuse-${FUSE_VERSION}.tar.gz"
SHA256="bcd19582c5e30f7fe45dd86a5540e998590aa01903afc7ebcbeea6c8ac5421ee"

# The triples build.zig looks for; keep in sync with README/AGENTS.md.
DEFAULT_TARGETS=(x86_64-linux-gnu aarch64-linux-gnu riscv64-linux-gnu)
targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=("${DEFAULT_TARGETS[@]}")

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for tool in meson ninja curl tar zig; do
    command -v "$tool" >/dev/null || {
        echo "$tool is required to build libfuse3 from source (pip install --user meson ninja)" >&2
        exit 1
    }
done

echo "Fetching $URL"
curl -fsSL -o "$tmp_dir/fuse.tar.gz" "$URL"

actual_sha="$(sha256sum "$tmp_dir/fuse.tar.gz" | awk '{print $1}')"
if [ "$actual_sha" != "$SHA256" ]; then
    echo "sha256 mismatch: expected $SHA256, got $actual_sha" >&2
    exit 1
fi

tar -xzf "$tmp_dir/fuse.tar.gz" -C "$tmp_dir"
src_dir="$tmp_dir/fuse-${FUSE_VERSION}"

for target in "${targets[@]}"; do
    echo "Building libfuse3 $FUSE_VERSION for $target"
    arch="${target%%-*}"
    build_dir="$tmp_dir/build-$target"
    prefix_dir="$tmp_dir/prefix-$target"

    # meson wants a cross file rather than a command line, and pkg-config is
    # pinned to /bin/false so the host's libraries cannot leak into a foreign
    # target's build.
    cat >"$tmp_dir/cross-$target.txt" <<EOF
[binaries]
c = ['zig', 'cc', '-target', '$target']
ar = ['zig', 'ar']
strip = ['zig', 'strip']
pkgconfig = '/bin/false'

[host_machine]
system = 'linux'
cpu_family = '$(case "$arch" in x86_64) echo x86_64;; aarch64) echo aarch64;; riscv64) echo riscv64;; esac)'
cpu = '$arch'
endian = 'little'
EOF

    # Static: the binary carries the library, so nothing but fusermount3 is
    # needed on the target. The helpers, examples and tests are not ours, and
    # io-uring support pulls in io_uring headers Zig's glibc may not carry.
    # disable-libc-symbol-version: libfuse otherwise exports every API symbol
    # through `.symver` aliases (fuse_loop_mt@@FUSE_3.12), which a static link
    # cannot resolve — the references stay plain `fuse_loop_mt` and read as
    # undefined.
    meson setup "$build_dir" "$src_dir" \
        --cross-file "$tmp_dir/cross-$target.txt" \
        --prefix "$prefix_dir" \
        --buildtype release \
        --default-library static \
        -Ddisable-libc-symbol-version=true \
        -Dutils=false \
        -Dexamples=false \
        -Dtests=false \
        -Denable-io-uring=false >/dev/null

    ninja -C "$build_dir" >/dev/null
    meson install -C "$build_dir" --no-rebuild >/dev/null

    # Replace any earlier unpack rather than merging into it, so a version bump
    # cannot leave stale headers behind.
    vendor_dir="$repo_root/vendor/fuse3/$target"
    rm -rf "$vendor_dir"
    mkdir -p "$vendor_dir"
    cp -r "$prefix_dir/include" "$vendor_dir/include"
    cp "$build_dir/lib/libfuse3.a" "$vendor_dir/libfuse3.a"
    echo "  vendor/fuse3/$target ($(du -h "$vendor_dir/libfuse3.a" | cut -f1))"
done

echo "Vendored libfuse3 $FUSE_VERSION for: ${targets[*]}"
