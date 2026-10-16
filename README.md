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
