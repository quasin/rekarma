# ReKarma

ReKarma - distributed recommendation system

### Installation

1. `bash install.sh`

### Components

1. Librats - https://github.com/librats
2. Autonomi - https://github.com/WithAutonomi
3. Zig - https://codeberg.org/ziglang

### librats and libfuse3

Nothing from either C dependency lives in the repository. `install.sh` builds
both from the pinned source tarballs and installs the results under `vendor/`,
which `.gitignore` excludes — one directory per target triple:

    vendor/librats/<triple>/include/, librats.a   the engine   (3.0.4, sha256
                                                                36e21f34cebef6fb0845f6498f1d91f9c62b944f9a594fe1899b702337f89a1a)
    vendor/fuse3/<triple>/include/, libfuse3.a    the mount    (3.18.3, sha256
                                                                bcd19582c5e30f7fe45dd86a5540e998590aa01903afc7ebcbeea6c8ac5421ee)

`<triple>` is `x86_64-linux-gnu`, `aarch64-linux-gnu` or `riscv64-linux-gnu`.

    bash scripts/fetch-librats.sh    # after a clone, or to re-fetch/bump
    bash scripts/fetch-fuse3.sh      # the same, for the mount library

Both take an optional triple list (`bash scripts/fetch-librats.sh
aarch64-linux-gnu`) and replace the triple's directory wholesale. `zig build`
refuses to start with a pointed message when the triple it builds for was never
vendored.

Both are built by Zig's own driver (`zig cc` / `zig c++ -target <triple>`), not
by a cross toolchain: it needs no root, and it emits objects against Zig's
bundled libc++/glibc, which is what the final link uses. That is what lets one
tree produce all three binaries:

    zig build                                 # host -> zig-out/bin/rekarma
    zig build dist                            # all three -> zig-out/<triple>/rekarma
    zig build -Dtarget=aarch64-linux-gnu

Requirements: `cmake`, `make`, `curl`, `tar`, plus `meson` and `ninja` for
libfuse3 (`pip install --user meson ninja`), and Zig 0.17.0. libfuse3 headers are
no longer needed to build — the library is vendored — but `fusermount3` is still
needed at run time, because that is the helper libfuse execs to mount.

The engine is built from source, not from the prebuilt release archive, for one
reason: `RATS_SEARCH_FEATURES` — the whole bittorrent stack, magnet links
included — is off in the CMake defaults, so the release archives ship
`rats_bt_add_magnet` and friends as stubs answering `RATS_ERR_NOT_ENABLED`.
`--magnet` needs a library that really has that stack, so
`scripts/fetch-librats.sh` configures the build with `-DRATS_SEARCH_FEATURES=ON
-DRATS_STORAGE=ON`.

Three things to know about the result:

1. `cmake --install` generates `include/librats/util/features.h`, which every
   public header reaches through `rats_export.h`; the source build supplies it,
   so the hand-written shim the old release-based fetch needed is gone.
2. the version `--version` prints is the library's own, read through
   `rats_version()`/`rats_version_string()`. A tarball has no `.git`, so librats
   would otherwise report the hardcoded `1.0.0.0`; the fetch script passes
   `-DRATS_VERSION_OVERRIDE=<pin>` and reads the generated `version.h` back, so
   the binary reports the tag it was really built from (`3.0.4.0`).
3. both archives are compiled against Zig's bundled libc++, so the executable
   links `link_libcpp` and needs no system libstdc++ — the `-Dlibstdcpp=` and
   `-Dlibgcc_s=` options are gone.

`--magnet` serves the mount through `src/fuse_glue.c` and `src/magnet_shim.cpp`;
the shim is compiled by Zig's C++ driver against the vendored headers, so the
`private`-spelled-public members it touches are the ones the library was built
from.

### Build

    zig build run

### The room

The program joins one librats pubsub room and records the last messages the room
carries in that room's file — `all.txt`, 1000 messages, room `rekarma`, all three
changeable:

    rekarma                          record the default room in the foreground
    rekarma "hello peers"            publish into the room, then exit
    rekarma --stay "hello peers"     publish, then keep recording
    rekarma -r news -f "logs/{room}.txt" -n 50
    rekarma --show                   print all.txt's last 1000 messages and exit
    rekarma --help                   every option

A message on the command line is a one-shot send: the node waits briefly for
somebody to be in the room, publishes, and exits once the message is out — a
sender neither creates nor trims the room's file. `--stay` keeps recording after
publishing instead.

### The daemon

`rekarma --daemon` is the recording node, detached:

    rekarma --daemon                 record the default room in all.txt, in the background
    rekarma --daemon -r news -f "logs/{room}.txt" -n 50
    kill $(cat all.txt.pid)          stop it (SIGTERM, the same path as Ctrl-C)

It forks into a session of its own — so it keeps running when the terminal that
started it closes — and its stdout and stderr are appended to a log file, since
a detached process has nowhere else to print its banner, its notices and
librats' own errors:

    all.txt          the room's messages (--file)
    all.txt.log      the daemon's own output (--log)
    all.txt.pid      its pid (--pid)

Both default to sitting next to the room's file; `--log` and `--pid` name them
explicitly, and `{room}` is replaced by the room name in them as it is in
`--file`.

Nodes find each other through the DHT keyed by the room name (plus mDNS on one
local network); `--no-discovery --connect host:port` wires two of them by hand.
A foreground run stays up until Ctrl-C.

NAT traversal is on by default: the node asks the router for its port over
UPnP/NAT-PMP and allows hole punching, because a DHT-discovered peer is only
reachable if its advertised address is. When a discovered peer cannot be dialed,
the node says so (`no route to <addr>`) rather than staying silent.

Two caveats worth knowing before blaming the DHT:

- Two nodes on one machine (or one LAN) meet over mDNS, never over the DHT: the
  DHT advertises the public address, and a dial to it has to come back through
  the router, which most routers only allow if the address is really ours.
- Behind double NAT / carrier-grade NAT nothing inbound can reach the advertised
  address at all. Use `--serve-relay` on some node so the others can route
  through it, or `--connect` to wire the two ends directly.

`--no-mdns`, `--no-dht` and `--no-nat` isolate one layer at a time.

### Mounting a release (FUSE 3)

`--magnet` and `--torrent` mount a torrent instead of recording a room: the
release appears as a read-only directory tree, its entries come from the
torrent's metadata, and the bytes of a file are fetched only when something
reads them. `--magnet` gets the metadata from the swarm (BEP 9), `--torrent`
reads it out of a `.torrent` file — which is why a torrent file can be browsed
with no peer at all, and why it is the way to mount a release the tracker or DHT
cannot find.

    rekarma --magnet 'magnet:?xt=urn:btih:…'        # mounts at mnt/<name>
    rekarma --magnet 'magnet:?xt=urn:btih:…' -m /mnt/rel --cache /var/cache/rekarma
    rekarma --magnet 81db4118adc4332d9d1cfff9d80667c4dfcf5848   # bare info-hash
    rekarma --torrent ~/release.torrent -m /mnt/rel  # metadata from the file

    rekarma --magnet '<hash>' --daemon               # mount in the background
    rekarma --torrent release.torrent --daemon       # the same, from a file
    kill $(cat .rekarma/magnet.pid)                   # unmount and stop

    ls -R /mnt/rel                    # metadata only: no payload is fetched
    mpv "/mnt/rel/<file>"             # reads on demand, piece by piece
    umount /mnt/rel                   # or Ctrl-C in the serving terminal

Quote the link in the shell — `?` and `&` are special there — or pass a bare
40-hex / 32-base32 info-hash, which is completed into a magnet link internally.
`-c host:port` seeds peers into the torrent as well as into the node, which is
how a magnet with no trackers and no DHT is wired by hand.

With `--daemon` the mount is served by a detached process, like the room's
recorder: the foreground command forks before the bittorrent client exists,
prints the pid and exits, and the child keeps the mount alive with its output in
`<cache>/magnet.log` and its pid in `<cache>/magnet.pid` (`--log` / `--pid`
override both). `kill $(cat <pid file>)` unmounts through the same SIGTERM path
as Ctrl-C. A read that has to wait for the swarm says so in that log
(`waiting for pieces N..M (… peers)`), so a slow start or a seek is visibly a
wait rather than a hang. A read is never aborted on elapsed time: while the
torrent still has peers it keeps waiting (64 MB of lookahead),
and only a swarm that has disappeared makes it fail — a player cannot retry a
failed read, and that error is what looks like "playback stops mid-file".

How it works: `src/magnet_shim.cpp` (C++) drives librats' bittorrent client — the
C bindings stop at "add magnet, download everything", while a mount needs the
metadata, piece priorities and piece reads — and `src/magnet_fs.zig` +
`src/fuse_glue.c` serve the file tree. Every piece starts as `DontDownload`; a
read marks the pieces it covers (plus a few ahead) as `High` and blocks until
they verify, so an untouched file costs nothing and a mounted 100 GB release
does not pull 100 GB. Seeking is the same mechanism: the pieces of every read
still in flight stay prioritised, so a seek does not starve the read it
interrupted. Pieces land in `--cache` (`[.rekarma]`), keyed by the torrent's own
paths, so a second run resumes what is already there.
