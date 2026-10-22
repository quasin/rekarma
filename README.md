# ReKarma

ReKarma - distributed recommendation system

### Installation

1. `bash install.sh`

### Components

1. Librats - https://github.com/librats
2. Autonomi - https://github.com/WithAutonomi
3. Zig - https://codeberg.org/ziglang

### librats

Nothing from librats lives in the repository. `install.sh` builds librats from
the pinned source tarball (3.0.2, sha256
`4454af32d2585be892c72307468633f7465f3e79eda0ff0b0bdfe5401dbc5c3d`) and installs
the result into `vendor/librats/`, which `.gitignore` excludes:

    vendor/librats/include/    librats public headers + generated features.h
    vendor/librats/librats.a   static library

    bash scripts/fetch-librats.sh    # after a clone, or to re-fetch/bump

`zig build` refuses to start with a pointed message when `vendor/librats/` is
missing.

The build is from source, not from the prebuilt release archive, for one reason:
`RATS_SEARCH_FEATURES` — the whole bittorrent stack, magnet links included — is
off in the CMake defaults, so the release archives ship `rats_bt_add_magnet` and
friends as stubs answering `RATS_ERR_NOT_ENABLED`. `--magnet` needs a library
that really has that stack, so `scripts/fetch-librats.sh` configures the build
with `-DRATS_SEARCH_FEATURES=ON -DRATS_STORAGE=ON` and therefore needs `cmake`,
`g++` and `make` (`apt install cmake g++ make` or the distribution's equivalent).

Two things to know about the result:

1. `cmake --install` generates `include/librats/util/features.h`, which every
   public header reaches through `rats_export.h`; the source build supplies it,
   so the hand-written shim the old release-based fetch needed is gone.
2. `librats.a` is C++ compiled with GCC's libstdc++ (`__cxx11` ABI), so the
   executable links the system libstdc++ and libgcc_s rather than Zig's bundled
   libc++. Override the paths with `-Dlibstdcpp=` / `-Dlibgcc_s=` if they live
   elsewhere.

`--magnet` also needs libfuse3 at build and run time (`fuse3-devel` /
`libfuse3-dev`); the mount is served through `src/fuse_glue.c`.

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

`--magnet` mounts a torrent instead of recording a room: the release appears as
a read-only directory tree, its entries come from the torrent's metadata, and
the bytes of a file are fetched only when something reads them.

    rekarma --magnet 'magnet:?xt=urn:btih:…'        # mounts at mnt/<name>
    rekarma --magnet 'magnet:?xt=urn:btih:…' -m /mnt/rel --cache /var/cache/rekarma
    rekarma --magnet 81db4118adc4332d9d1cfff9d80667c4dfcf5848   # bare info-hash

    rekarma --magnet '<hash>' --daemon               # mount in the background
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
