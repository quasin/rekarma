/*
 * The bittorrent half of `rekarma --magnet`, behind a small C ABI.
 *
 * Why a C++ shim at all: the librats C bindings expose exactly four torrent
 * calls — enable, add magnet, add torrent file, remove — and all four are
 * download-oriented ("start a download into a directory"). A mounted release
 * needs three things those calls do not answer: the torrent's metadata (file
 * list, sizes, piece geometry), whether a given piece is on disk yet, and a
 * piece read that is safe while the engine is still writing. All three exist in
 * librats' C++ API, so this file is a translation layer, nothing more:
 *
 *   metadata  -> bittorrent::Client::torrent_metadata (a thread-safe snapshot)
 *   progress  -> bittorrent::Client::torrent_status
 *   have/read -> bittorrent::Torrent's piece picker and disk layer
 *
 * The last line is the one compromise worth naming: Torrent keeps its picker
 * and disk behind private members and offers no public accessor or priority
 * API, so this file compiles against the same headers with `private` spelled
 * `public` (see kPrivateHack below). Everything it then touches is a member
 * whose layout is fixed by the headers the library was built from — the same
 * 3.0.2 headers vendored into vendor/librats — and every access happens on the
 * reactor thread through Reactor::post, which is the thread the engine itself
 * uses and the only one those members are safe on.
 *
 * Zig calls rek_bt_* from the FUSE worker threads: those are plain reads, one
 * blocking call per FUSE request, and never touch librats state directly.
 */

// std must be fully included before `private` is redefined, or the standard
// library's own members would be rewritten in this translation unit.
#include <bits/stdc++.h>

#define private public
#include <librats/bittorrent/client.h>
#include <librats/bittorrent/magnet_uri.h>
#include <librats/bittorrent/torrent.h>
#include <librats/bittorrent/torrent_info.h>
#include <librats/dht/dht.h>
#undef private

#include <cerrno>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>

using namespace librats;
using namespace librats::bittorrent;

extern "C" {

struct rek_bt_file {
    const char* path;   /* relative, '/'-separated, owned by rek_bt */
    int64_t     size;
    int64_t     offset; /* start of the file in the torrent's byte space */
};

struct rek_bt_progress {
    int      has_metadata;
    uint64_t total_size;
    uint64_t downloaded;
    size_t   peers;
    double   progress;
};

struct rek_bt {
    std::unique_ptr<Client>    client;
    std::unique_ptr<DhtClient> dht;
    InfoHash                   hash{};
    Torrent*                   torrent = nullptr;
    PiecePicker*               picker  = nullptr;
    DiskIo*                    disk    = nullptr;

    std::string              name;
    std::vector<std::string> paths;   /* storage for rek_bt_file::path */
    std::vector<rek_bt_file> files;
    uint32_t                 piece_length = 0;
    uint32_t                 num_pieces   = 0;
    uint64_t                 total_size   = 0;

    struct Range {
        uint32_t first;
        uint32_t last;
    };

    /* Every read currently waiting, so a seek (which starts a new read while the
       old one is still blocked) cannot drop the pieces the old one needs: the
       priorities are the union of all active windows. Guarded by a mutex
       because the readers are FUSE worker threads. */
    std::mutex          active_mutex;
    std::vector<Range>  active;

    /* Pieces currently marked High. Reactor thread only. */
    std::vector<uint32_t> hot;

    /// The one piece left Wanted outside the windows (see pump_range).
    uint32_t keepalive = 0;
};

void rek_bt_close(rek_bt* bt);

} // extern "C"

namespace {

void set_error(char* err, size_t err_len, const char* message) {
    if (!err || err_len == 0) return;
    std::snprintf(err, err_len, "%s", message);
}

/// Run @p fn on the reactor and wait for it. Every librats member this file
/// reaches into belongs to that thread.
void on_reactor(Client& client, const std::function<void()>& fn) {
    auto done = std::make_shared<std::promise<void>>();
    auto future = done->get_future();
    client.reactor().post([fn, done] {
        fn();
        done->set_value();
    });
    future.wait();
}

/// A piece read issued from the FUSE thread, completed by the disk worker and
/// marshalled back onto the reactor by ThreadedDiskIo's poster.
struct ReadSlot {
    std::mutex              mutex;
    std::condition_variable cv;
    bool                    done = false;
    bool                    ok   = false;
    Bytes                   data;
};

bool read_piece(DiskIo& disk, uint32_t piece, uint32_t offset, uint32_t length, Bytes& out, int timeout_ms) {
    auto slot = std::make_shared<ReadSlot>();
    disk.async_read(piece, offset, length, [slot](bool ok, Bytes data) {
        {
            std::lock_guard<std::mutex> lock(slot->mutex);
            slot->ok   = ok;
            slot->data = std::move(data);
            slot->done = true;
        }
        slot->cv.notify_all();
    });
    std::unique_lock<std::mutex> lock(slot->mutex);
    if (!slot->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [slot] { return slot->done; }))
        return false;
    if (!slot->ok || slot->data.size() != length) return false;
    out = std::move(slot->data);
    return true;
}

/// How far past a read's end to keep fetching, in bytes. A player reads a few
/// hundred KB at a time and wants the next second of video already here; 16 MB
/// covers that at any sane bitrate. Expressed in bytes rather than pieces
/// because piece length is the torrent's choice — 32 pieces of a 4 MB-piece
/// torrent would be 128 MB of lookahead per read.
constexpr uint64_t kPrefetchBytes = 64ull * 1024 * 1024;

/// Pieces behind a read's start that stay prioritised: a window that advances in
/// 128 KB steps would otherwise drop a piece that is halfway through its blocks
/// every step, throwing the work away and stalling the reader on its retry.
constexpr uint32_t kKeepBehindPieces = 4;

/// Ask the picker how many pieces of [first, last] are still missing, and make
/// the swarm work on exactly the neighbourhood of that range: High for the
/// range plus kPrefetchPieces ahead, DontDownload for everything else that is
/// not already here. That last part is what keeps a mounted release from
/// pulling the whole torrent in the background — the mount is a reader, not a
/// downloader, and an untouched file costs nothing.
///
/// One piece outside the window is left Wanted on purpose: a picker with
/// nothing wanted reports the torrent as finished, which makes librats flip to
/// Seeding and stop growing the peers it needs for the next read.
uint32_t pump_range(rek_bt& bt, uint32_t first, uint32_t last) {
    uint32_t missing = 0;
    on_reactor(*bt.client, [&] {
        if (!bt.picker || bt.num_pieces == 0) return;
        const uint32_t last_piece = bt.num_pieces - 1;

        // A window per waiting read: a seek starts a second read while the first
        // is still blocked, and dropping the first one's pieces (what a single
        // "current window" would do) leaves that read waiting out its timeout —
        // which is exactly "playback stops after seeking".
        std::vector<rek_bt::Range> windows;
        {
            std::lock_guard<std::mutex> lock(bt.active_mutex);
            windows.reserve(bt.active.size());
            for (const rek_bt::Range& range : bt.active) {
                if (range.first > last_piece) continue;
                const std::uint64_t end_byte =
                    (std::min(range.last, last_piece) + 1ull) * bt.piece_length + kPrefetchBytes;
                const uint32_t window_last = static_cast<uint32_t>(
                    std::min<std::uint64_t>(last_piece, end_byte / bt.piece_length));
                windows.push_back(rek_bt::Range{
                    range.first > kKeepBehindPieces ? range.first - kKeepBehindPieces : 0,
                    window_last,
                });
            }
        }
        auto in_window = [&](uint32_t piece) {
            for (const rek_bt::Range& window : windows)
                if (piece >= window.first && piece <= window.last) return true;
            return false;
        };

        // Only pieces that left every window are dropped, and only the ones that
        // are not already here: no rescan of all pieces per read, which at 30 000
        // pieces would cost more than the download it schedules.
        for (uint32_t piece : bt.hot) {
            if (in_window(piece)) continue;
            if (!bt.picker->have_piece(piece)) bt.picker->set_piece_priority(piece, PiecePriority::DontDownload);
        }

        std::vector<uint32_t> hot;
        for (const rek_bt::Range& window : windows) {
            for (uint32_t piece = window.first; piece <= window.last; ++piece) {
                if (std::find(hot.begin(), hot.end(), piece) == hot.end()) hot.push_back(piece);
                if (!bt.picker->have_piece(piece)) bt.picker->set_piece_priority(piece, PiecePriority::High);
            }
        }
        for (uint32_t piece = first; piece <= std::min(last, last_piece); ++piece)
            if (!bt.picker->have_piece(piece)) ++missing;
        bt.hot = std::move(hot);

        // Keep exactly one wanted piece outside the windows, so the picker never
        // reports "finished" (which makes librats slide into Seeding and stop
        // growing the peers the next read will need).
        if (bt.keepalive < bt.num_pieces && bt.picker->have_piece(bt.keepalive)) {
            bt.keepalive = bt.num_pieces;
            for (uint32_t piece = 0; piece <= last_piece; ++piece) {
                if (bt.picker->have_piece(piece) || in_window(piece)) continue;
                bt.keepalive = piece;
                break;
            }
        }
        if (bt.keepalive < bt.num_pieces && !in_window(bt.keepalive))
            bt.picker->set_piece_priority(bt.keepalive, PiecePriority::Normal);

        // Priorities alone do not reach the peers: interest is what makes a peer
        // unchoke us, and it is only recomputed on HAVE/bitfield events. Without
        // this a read of a piece nobody advertised yet would wait forever.
        for (PeerConnection* pc : bt.torrent->peers_) bt.torrent->update_interest(*pc);
    });
    return missing;
}

void collect_metadata(rek_bt& bt, const TorrentInfo& info) {
    bt.name         = info.name();
    bt.piece_length = info.piece_length();
    bt.num_pieces   = info.num_pieces();
    bt.total_size   = static_cast<uint64_t>(info.total_size());

    bt.paths.clear();
    bt.files.clear();
    const FileStorage& storage = info.files();
    bt.paths.reserve(storage.num_files());
    bt.files.reserve(storage.num_files());
    for (size_t i = 0; i < storage.num_files(); ++i) {
        const FileEntry& entry = storage.file_at(i);
        bt.paths.push_back(entry.path);
    }
    for (size_t i = 0; i < storage.num_files(); ++i) {
        const FileEntry& entry = storage.file_at(i);
        bt.files.push_back(rek_bt_file{bt.paths[i].c_str(), entry.size, entry.offset});
    }
}

/// What a user actually has on the clipboard is not always a full URI: a bare
/// 40-hex info-hash is what a tracker page or a magnet-less client hands out,
/// and `xt=urn:btih:…` is the link minus its scheme. Both are accepted and
/// completed here, because refusing them would only send the user back to the
/// shell — where `?` and `&` are the next problem.
std::string normalize_magnet(const std::string& input) {
    auto starts_with = [&](const char* prefix) { return input.rfind(prefix, 0) == 0; };

    if (starts_with("magnet:?")) return input;
    if (starts_with("magnet:")) return "magnet:?" + input.substr(7);
    if (starts_with("xt=urn:btih:")) return "magnet:?" + input;
    if (starts_with("urn:btih:")) return "magnet:?xt=" + input;
    if (starts_with("btih:")) return "magnet:?xt=urn:" + input;

    const bool hex40 = input.size() == 40 &&
        std::all_of(input.begin(), input.end(), [](unsigned char c) { return std::isxdigit(c) != 0; });
    const bool base32_32 = input.size() == 32 &&
        std::all_of(input.begin(), input.end(), [](unsigned char c) {
            return (c >= 'A' && c <= 'Z') || (c >= '2' && c <= '7');
        });
    if (hex40 || base32_32) return "magnet:?xt=urn:btih:" + input;

    return input;
}

} // namespace

extern "C" {

rek_bt* rek_bt_open(const char* magnet_uri, const char* cache_dir, uint16_t port, int enable_dht,
                    char* err, size_t err_len) {
    if (!magnet_uri || !cache_dir) {
        set_error(err, err_len, "a magnet link and a cache directory are required");
        return nullptr;
    }
    // The normalized form is what the engine and the parser see; the caller's
    // string may be a bare hash or a scheme-less xt=.
    const std::string magnet = normalize_magnet(magnet_uri);
    auto parsed = MagnetUri::parse(magnet);
    if (!parsed || !parsed->is_valid()) {
        set_error(err, err_len,
                  "not a magnet link or info-hash (magnet:?xt=urn:btih:<40 hex or 32 base32>); "
                  "quote the link in the shell, '?' and '&' are special there");
        return nullptr;
    }

    std::error_code ec;
    std::filesystem::create_directories(cache_dir, ec);
    if (ec) {
        set_error(err, err_len, "cannot create the cache directory");
        return nullptr;
    }

    auto bt = std::make_unique<rek_bt>();
    bt->hash = parsed->info_hash;

    Client::Config config;
    config.listen_port   = port;
    config.download_path = cache_dir;
    bt->client = std::make_unique<Client>(config);

    if (enable_dht) {
        // A magnet has no peer list of its own beyond trackers, and a torrent
        // with no trackers would never find anything: one DHT client, bootstrapped
        // and handed to the session, is the peer source. Failure is not fatal —
        // trackers and --connect peers still work.
        bt->dht = std::make_unique<DhtClient>(0);
        if (bt->dht->start()) {
            bt->dht->bootstrap(DhtClient::get_default_bootstrap_nodes());
            bt->client->set_external_dht(bt->dht.get());
        }
    }

    bt->client->start();
    bt->torrent = bt->client->add_magnet(magnet, cache_dir);
    if (!bt->torrent) {
        rek_bt_close(bt.release());
        set_error(err, err_len, "librats refused the magnet link");
        return nullptr;
    }
    return bt.release();
}

void rek_bt_close(rek_bt* bt) {
    if (!bt) return;
    if (bt->client) bt->client->stop();
    if (bt->dht) bt->dht->stop();
    delete bt;
}

void rek_bt_add_peer(rek_bt* bt, const char* host, uint16_t port) {
    if (!bt || !bt->torrent || !host) return;
    const std::string ip(host);
    // Torrent::add_peer touches the peer list directly, so it belongs on the
    // reactor like every other engine call.
    on_reactor(*bt->client, [bt, ip, port] { bt->torrent->add_peer(ip, port); });
}

int rek_bt_wait_metadata(rek_bt* bt, int timeout_ms) {
    if (!bt) return -EINVAL;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    for (;;) {
        auto info = bt->client->torrent_metadata(bt->hash);
        if (info) {
            collect_metadata(*bt, *info);
            // Cache the two engine handles once metadata exists: both are
            // allocated exactly once, on the reactor, and live until the torrent
            // is destroyed. Sequential picking is the mode a reader wants — it
            // walks the torrent in file order instead of rarest-first.
            on_reactor(*bt->client, [bt] {
                bt->picker = bt->torrent->picker_.get();
                bt->disk   = bt->torrent->disk_.get();
                if (!bt->picker) return;
                bt->picker->set_mode(PickMode::Sequential);
                // Park the whole torrent until somebody reads: the metadata is
                // all a mount needs to browse, and libtorrent-style clients
                // start every file in a release the moment it is added, which is
                // exactly what a mounted release must not do.
                uint32_t keepalive = bt->num_pieces;
                for (uint32_t p = 0; p < bt->num_pieces; ++p) {
                    if (bt->picker->have_piece(p)) continue;
                    bt->picker->set_piece_priority(p, PiecePriority::DontDownload);
                    if (keepalive == bt->num_pieces) keepalive = p;
                }
                if (keepalive != bt->num_pieces)
                    bt->picker->set_piece_priority(keepalive, PiecePriority::Normal);
                bt->keepalive = keepalive;
                bt->hot.clear();
            });
            if (!bt->picker || !bt->disk) return -EIO;
            return 0;
        }
        if (std::chrono::steady_clock::now() >= deadline) return -ETIMEDOUT;
        // Poll tightly: the engine starts requesting blocks the instant the info
        // dict lands and park() can only run on the reactor afterwards, so every
        // millisecond here is a millisecond of unwanted download.
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

size_t rek_bt_num_files(rek_bt* bt) { return bt ? bt->files.size() : 0; }
const rek_bt_file* rek_bt_files(rek_bt* bt) { return bt && !bt->files.empty() ? bt->files.data() : nullptr; }
const char* rek_bt_name(rek_bt* bt) { return bt ? bt->name.c_str() : ""; }
uint32_t rek_bt_piece_length(rek_bt* bt) { return bt ? bt->piece_length : 0; }
uint32_t rek_bt_num_pieces(rek_bt* bt) { return bt ? bt->num_pieces : 0; }
uint64_t rek_bt_total_size(rek_bt* bt) { return bt ? bt->total_size : 0; }

void rek_bt_state(rek_bt* bt, rek_bt_progress* out) {
    if (!out) return;
    *out = rek_bt_progress{};
    if (!bt || !bt->client) return;
    TorrentStatus status = bt->client->torrent_status(bt->hash);
    out->has_metadata = status.has_metadata ? 1 : 0;
    out->total_size   = status.total_size;
    out->downloaded   = status.downloaded;
    out->peers        = status.num_peers;
    out->progress     = status.progress;
}

/*
 * Read @p len bytes at @p offset of the torrent's byte space, blocking until the
 * pieces that cover them are on disk. Returns the count read, or -errno:
 * -ETIMEDOUT when the swarm does not deliver them within @p timeout_ms.
 */
int64_t rek_bt_read(rek_bt* bt, uint64_t offset, void* buffer, size_t len, int timeout_ms) {
    if (!bt || !buffer) return -EINVAL;
    if (!bt->picker || !bt->disk) return -ENODATA;
    if (len == 0) return 0;
    if (offset >= bt->total_size) return 0;
    if (offset + len > bt->total_size) len = static_cast<size_t>(bt->total_size - offset);

    const uint32_t piece_length = bt->piece_length;
    const uint32_t first = static_cast<uint32_t>(offset / piece_length);
    const uint32_t last  = static_cast<uint32_t>((offset + len - 1) / piece_length);

    // Register the range before waiting and unregister it afterwards (however
    // this returns): the window of a read that is still blocked must survive a
    // seek that starts another one.
    {
        std::lock_guard<std::mutex> lock(bt->active_mutex);
        bt->active.push_back(rek_bt::Range{first, last});
    }
    struct RangeGuard {
        rek_bt* bt;
        uint32_t first;
        uint32_t last;
        ~RangeGuard() {
            std::lock_guard<std::mutex> lock(bt->active_mutex);
            auto it = std::find_if(bt->active.begin(), bt->active.end(), [this](const rek_bt::Range& r) {
                return r.first == first && r.last == last;
            });
            if (it != bt->active.end()) bt->active.erase(it);
        }
    } range_guard{bt, first, last};

    // The bound is "no progress for timeout_ms", not "this read took
    // timeout_ms": a seek into a part of the release only one peer has is
    // legitimately slow, and aborting it is what makes a player stop instead of
    // waiting. Progress is counted in pieces of this read's own range.
    const auto started = std::chrono::steady_clock::now();
    auto last_progress = started;
    auto said          = started;
    uint32_t best      = std::numeric_limits<uint32_t>::max();
    uint32_t missing   = 0;
    while ((missing = pump_range(*bt, first, last)) != 0) {
        const auto now = std::chrono::steady_clock::now();
        if (missing < best) {
            best = missing;
            last_progress = now;
        }
        // A player has no way to retry a failed read: returning an error here is
        // what makes VLC stop mid-file. So the read keeps waiting while the
        // swarm can still deliver — progress within timeout_ms, or peers still
        // connected — and gives up only when there is nobody left to ask.
        if (now - last_progress >= std::chrono::milliseconds(timeout_ms)) {
            const std::size_t peers = bt->torrent->num_peers();
            if (peers == 0 || !bt->torrent->running_) {
                std::fprintf(stderr, "rekarma: gave up on pieces %u..%u: no progress for %lld ms, %zu peers\n",
                             first, last,
                             (long long)std::chrono::duration_cast<std::chrono::milliseconds>(now - last_progress).count(),
                             peers);
                return -ETIMEDOUT;
            }
            std::fprintf(stderr, "rekarma: still waiting for pieces %u..%u (%u missing, %zu peers) — slow swarm, holding the read\n",
                         first, last, missing, peers);
            last_progress = now; // say it again in another timeout_ms, do not abort
        }
        // Silence here is what made a reader look hung: say what is being waited
        // for, and from how many peers, while the swarm works.
        if (now - said >= std::chrono::seconds(3)) {
            said = now;
            std::fprintf(stderr, "rekarma: waiting for pieces %u..%u (%u missing, %zu peers, %lld ms)\n",
                         first, last, missing, bt->torrent->num_peers(),
                         (long long)std::chrono::duration_cast<std::chrono::milliseconds>(now - started).count());
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    auto* out = static_cast<uint8_t*>(buffer);
    size_t written = 0;
    for (uint32_t piece = first; piece <= last; ++piece) {
        const uint64_t piece_start = static_cast<uint64_t>(piece) * piece_length;
        const uint64_t from = std::max<uint64_t>(offset, piece_start);
        const uint64_t to   = std::min<uint64_t>(offset + len, piece_start + static_cast<uint64_t>(bt->picker->piece_size(piece)));
        if (to <= from) continue;
        const uint32_t in_piece = static_cast<uint32_t>(from - piece_start);
        const uint32_t want     = static_cast<uint32_t>(to - from);

        Bytes bytes;
        if (!read_piece(*bt->disk, piece, in_piece, want, bytes, timeout_ms)) return -EIO;
        std::memcpy(out + written, bytes.data(), bytes.size());
        written += bytes.size();
    }
    return static_cast<int64_t>(written);
}

} // extern "C"
