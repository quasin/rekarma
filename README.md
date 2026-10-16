# ReKarma

ReKarma - distributed recommendation system

### Installation

1. `bash install.sh`

### Components

1. Librats - https://github.com/librats
2. Autonomi - https://github.com/WithAutonomi
3. Zig - https://codeberg.org/ziglang

### librats

Nothing from librats lives in the repository. `install.sh` downloads the prebuilt
release `librats-linux-x64-3.0.0.zip`
(https://github.com/librats/librats/releases/download/3.0.0/librats-linux-x64-3.0.0.zip,
sha256 `84fd5cb4017c557c72e8c5c087c94b31e9a8f75188c2448cafe3da505b444931`) and
unpacks it into `vendor/librats/`, which `.gitignore` excludes. The same happens
by calling the script directly:

    vendor/librats/include/    librats public headers  (downloaded)
    vendor/librats/librats.a   static library linux-x64 (downloaded, 6 MB)

    bash scripts/fetch-librats.sh    # after a clone, or to re-fetch/bump

`zig build` refuses to start with a pointed message when `vendor/librats/` is
missing.

Two things to know about this release:

1. It does not ship the generated `include/librats/util/features.h`, which every
   public header reaches through `rats_export.h`, so the shipped headers cannot
   be included as-is. Our hand-written replacement is tracked at
   `scripts/librats/features.h` and the fetch script copies it into the unpacked
   tree.
2. `librats.a` is C++ compiled with GCC's libstdc++ (`__cxx11` ABI), so the
   executable links the system libstdc++ and libgcc_s rather than Zig's bundled
   libc++. Override the paths with `-Dlibstdcpp=` / `-Dlibgcc_s=` if they live
   elsewhere.

Prebuilt slices exist for linux-x64 only; other targets need librats built from
source.

### Build

    zig build run
