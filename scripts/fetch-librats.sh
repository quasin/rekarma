#!/usr/bin/env bash
# Build librats from source for each target and vendor the result into
# vendor/librats/<arch>-<os>-<abi>/ (include/ + librats.a).
#
# Nothing from librats is committed: vendor/ is generated, gitignored, and
# (re)created here — install.sh calls this script. Run it once after a clone,
# before `zig build`; rerun it to bump the pin. Pass targets to build a subset:
#
#     bash scripts/fetch-librats.sh aarch64-linux-gnu
#
# The prebuilt release archives (librats-linux-x64-*.zip) are built with the
# CMake defaults, and RATS_SEARCH_FEATURES — the whole bittorrent stack, magnet
# links included — is OFF by default: their rats_bt_* entry points are stubs
# that return RATS_ERR_NOT_ENABLED. `--magnet` needs a library that really has
# that stack, so the archive is not enough and the source build below turns the
# option on.
#
# The C++ compiler is Zig's own (`zig c++ -target <triple>`), not a cross-GCC:
# it needs no root, and it emits objects against Zig's bundled libc++, which is
# what the final binary links. That is also what makes the archive portable
# across architectures — a GCC-built one pulls in the system libstdc++/__cxx11
# ABI and cannot enter a cross-target link at all.
#
# The source tarball has no .git, so librats' CMake would fall back to the
# hardcoded 1.0.0.0 and `rats_version()` would report that whatever the pin
# says — `rekarma --version` then lies about the library it was built from.
# -DRATS_VERSION_OVERRIDE is the knob the project provides for tarball builds;
# the installed version.h is read back below so a build that ignored it fails
# here instead of printing a false version.
set -euo pipefail

LIBRATS_VERSION="3.0.5"
URL="https://github.com/librats/librats/archive/refs/tags/${LIBRATS_VERSION}.tar.gz"
SHA256="16fc743d27dc04cd9df7d47961942b984989aceccb735cb550f1dd57ce6fee68"

# The triples build.zig looks for; keep in sync with README/AGENTS.md.
DEFAULT_TARGETS=(x86_64-linux-gnu aarch64-linux-gnu riscv64-linux-gnu)
targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=("${DEFAULT_TARGETS[@]}")

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for tool in cmake make curl tar zig; do
    command -v "$tool" >/dev/null || {
        echo "$tool is required to build librats from source" >&2
        exit 1
    }
done

echo "Fetching $URL"
curl -fsSL -o "$tmp_dir/librats.tar.gz" "$URL"

actual_sha="$(sha256sum "$tmp_dir/librats.tar.gz" | awk '{print $1}')"
if [ "$actual_sha" != "$SHA256" ]; then
    echo "sha256 mismatch: expected $SHA256, got $actual_sha" >&2
    exit 1
fi

tar -xzf "$tmp_dir/librats.tar.gz" -C "$tmp_dir"
src_dir="$tmp_dir/librats-${LIBRATS_VERSION}"

for target in "${targets[@]}"; do
    echo "Building librats $LIBRATS_VERSION for $target"
    build_dir="$tmp_dir/build-$target"

    # cmake wants a single compiler path, and the target has to ride along, so
    # each target gets a two-line wrapper.
    printf '#!/bin/sh\nexec zig cc -target %s "$@"\n' "$target" >"$tmp_dir/cc-$target"
    printf '#!/bin/sh\nexec zig c++ -target %s "$@"\n' "$target" >"$tmp_dir/cxx-$target"
    chmod +x "$tmp_dir/cc-$target" "$tmp_dir/cxx-$target"

    # Search features ON is the point of building here (magnet/bittorrent).
    # Tests, the reference client and the examples are not part of the library
    # we vendor. Static only: the binary must not need librats.so at runtime.
    # -g0: `zig c++` emits debug info by default, which turns ~8 MB of archive
    # into ~80 MB and lands in the binary.
    cmake -S "$src_dir" -B "$build_dir" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR="${target%%-*}" \
        -DCMAKE_C_COMPILER="$tmp_dir/cc-$target" \
        -DCMAKE_CXX_COMPILER="$tmp_dir/cxx-$target" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-g0" \
        -DCMAKE_CXX_FLAGS="-g0" \
        -DRATS_VERSION_OVERRIDE="$LIBRATS_VERSION" \
        -DRATS_SEARCH_FEATURES=ON \
        -DRATS_STORAGE=ON \
        -DRATS_BUILD_TESTS=OFF \
        -DRATS_BUILD_CLIENT=OFF \
        -DRATS_BUILD_EXAMPLES=OFF \
        -DRATS_STATIC_LIBRARY=ON \
        -DRATS_SHARED_LIBRARY=OFF >/dev/null

    cmake --build "$build_dir" -j"$(nproc)" >/dev/null

    # `cmake --install` is what puts the generated librats/util/version.h (and
    # features.h) beside the public headers; the release archive ships neither
    # (the old fetch script had to supply a hand-written features.h).
    cmake --install "$build_dir" --prefix "$tmp_dir/prefix-$target" >/dev/null

    # The linked library must report the pinned tag, or --version lies.
    version_h="$tmp_dir/prefix-$target/include/librats/util/version.h"
    major="${LIBRATS_VERSION%%.*}"
    rest="${LIBRATS_VERSION#*.}"
    minor="${rest%%.*}"
    patch="${rest#*.}"
    for want in "MAJOR $major" "MINOR $minor" "PATCH $patch"; do
        field="${want%% *}"
        value="${want##* }"
        grep -q "LIBRATS_VERSION_${field} ${value}\$" "$version_h" || {
            echo "version.h does not say $field=$value:" >&2
            grep "LIBRATS_VERSION_${field} " "$version_h" >&2
            exit 1
        }
    done

    # Replace any earlier unpack rather than merging into it, so a version bump
    # cannot leave stale headers behind.
    vendor_dir="$repo_root/vendor/librats/$target"
    rm -rf "$vendor_dir"
    mkdir -p "$vendor_dir"
    cp -r "$tmp_dir/prefix-$target/include" "$vendor_dir/include"
    cp "$tmp_dir/prefix-$target/lib/librats.a" "$vendor_dir/librats.a"
    echo "  vendor/librats/$target ($(du -h "$vendor_dir/librats.a" | cut -f1))"
done

echo "Vendored librats $LIBRATS_VERSION for: ${targets[*]}"
