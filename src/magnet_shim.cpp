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
 * 3.0.5 headers vendored into vendor/librats — and every access happens on the
 * reactor thread through Reactor::post, which is the thread the engine itself
 * uses and the only one those members are safe on.
 *
 * Zig calls rek_bt_* from the FUSE worker threads: those are plain reads, one
 * blocking call per FUSE request, and never touch librats state directly.
 */

// std must be fully included before `private` is redefined, or the standard
// library's own members would be rewritten in this translation unit. The list is
// spelled out instead of <bits/stdc++.h> because this file is compiled by Zig's
// C++ driver against the bundled libc++, which has no GCC internal headers.
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <functional>
#include <future>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <utility>
#include <vector>

// Disk-side eviction: FALLOC_FL_PUNCH_HOLE frees a piece's blocks without
// changing the file's size, and statvfs is what "cache limit auto" is computed
// from. Both come from the kernel headers directly — a `-std=c++11` build has no
// _GNU_SOURCE, so fallocate()/statvfs() would not be declared.
#include <fcntl.h>
#include <linux/falloc.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <unistd.h>

#define private public
#include <librats/bittorrent/client.h>
#include <librats/bittorrent/magnet_uri.h>
#include <librats/bittorrent/torrent.h>
#include <librats/bittorrent/torrent_info.h>
#include <librats/bittorrent/tracker.h>
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

/// What a mount may spend on the host it runs on. Fixed at open time: the limit
/// is enforced by the eviction pass in rek_bt_read, and the window is read by
/// every pump_range.
///
/// `cache_limit` 0 means unbounded — the historical behaviour, where the cache
/// grows to whatever was read and never shrinks. Anything else is a hard cap:
/// cold pieces are dropped from disk and re-fetched when somebody reads them
/// again, which is what lets a 10 GB machine mount a 2 TB release. `prefetch` 0
/// means the built-in 128 MiB read-ahead.
struct rek_bt_config {
    uint64_t cache_limit;
    uint64_t prefetch;
    /// Block requests to keep in flight per peer (0 = librats' own 16). See
    /// kRefillChunk for why 16 is not enough for streaming.
    uint32_t pipeline;
};

struct rek_bt {
    std::unique_ptr<Client>    client;
    std::unique_ptr<DhtClient> dht;
    InfoHash                   hash{};
    Torrent*                   torrent = nullptr;
    PiecePicker*               picker  = nullptr;
    DiskIo*                    disk    = nullptr;

    std::string              name;
    std::string              cache_root; /* the directory pieces are written to */
    std::vector<std::string> paths;   /* storage for rek_bt_file::path */
    std::vector<rek_bt_file> files;
    uint32_t                 piece_length = 0;
    uint32_t                 num_pieces   = 0;
    uint64_t                 total_size   = 0;

    /* Cache budget in bytes: kept under `cache_limit`, evicted down to
       `cache_target` (a little below it, so one read does not evict exactly one
       piece's worth and immediately refill it). 0 = unbounded. */
    uint64_t cache_limit  = 0;
    uint64_t cache_target = 0;
    /// Read-ahead per active window, in bytes (0 = kPrefetchBytes).
    uint64_t prefetch_bytes = 0;
    /// Block requests kept in flight per peer (0 = librats' own 16). See
    /// deep_refill() for why 16 is not enough to stream a film.
    uint32_t pipeline_blocks = 0;
    /// Stops the refill timer when the session goes away: it can fire while
    /// client->stop() is joining the reactor thread.
    std::shared_ptr<std::atomic<bool>> refill_alive;
    bool refill_timer_armed = false;

    /// Per-peer delivery pace, so a deep queue is handed to peers that actually
    /// deliver instead of being split evenly over the swarm (see deep_refill).
    /// Keyed by the raw connection pointer; only touched on the reactor thread.
    struct PeerPace {
        double   rate  = 0.0;  ///< bytes per second, smoothed
        uint64_t bytes = 0;    ///< the engine's per-peer byte counter, last sample
    };
    std::unordered_map<const void*, PeerPace> pace;
    std::chrono::steady_clock::time_point     pace_at{};

    /// Pieces a reader is waiting for that are taking too long: when they were
    /// first noticed, so their outstanding blocks can be requested a second time
    /// from a peer that is delivering (see duplicate_late_piece).
    std::unordered_map<uint32_t, std::chrono::steady_clock::time_point> late;
    /// Blocks whose second copy was requested for a late piece (see
    /// duplicate_piece). Reported on the "still waiting" line so a stall can be
    /// told apart from a swarm that simply has nothing.
    std::uint64_t duplicate_blocks = 0;
    /// Where the next eviction pass starts looking. A rotating cursor instead of
    /// a scan from piece 0 keeps eviction as cheap on a 500 000-piece torrent as
    /// on a 50-piece one.
    uint32_t evict_cursor = 0;
    /// Last measured on-disk footprint of the cache and when it was measured:
    /// statting every file of the release on every read would cost more than the
    /// read itself, so the number is sampled a few times a second.
    uint64_t cache_bytes = 0;
    std::chrono::steady_clock::time_point cache_bytes_at{};

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

    /* Pieces a read has touched recently, so a player's re-read of the same
       block is not evicted between its own reads. Bounded: this bookkeeping must
       not grow with the torrent. */
    std::mutex                   recent_mutex;
    std::deque<uint32_t>         recent;
    std::unordered_set<uint32_t> recent_set;
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
/// hundred KB at a time and wants the next second of video already here; the
/// window is deliberately generous (128 MB) because a seek costs a full stall
/// while the first piece of the new position is fetched, and the extra depth is
/// what keeps a 4K stream ahead of itself on a fast swarm. Expressed in bytes
/// rather than pieces because piece length is the torrent's choice — 32 pieces
/// of a 4 MB-piece torrent would be 128 MB of lookahead per read.
constexpr uint64_t kPrefetchBytes = 128ull * 1024 * 1024;

/// Pieces behind a read's start that stay prioritised: a window that advances in
/// 128 KB steps would otherwise drop a piece that is halfway through its blocks
/// every step, throwing the work away and stalling the reader on its retry.
constexpr uint32_t kKeepBehindPieces = 4;

/// How many recently-read pieces are remembered (see rek_bt::recent): enough for
/// a player's re-reads, small enough that the bookkeeping is a rounding error on
/// a 1 GB machine.
constexpr size_t kRecentPieces = 4096;

/// How much of the budget the recent ring may protect. Never more than a quarter:
/// a ring that covered the whole cache would leave nothing evictable and the limit
/// could not be enforced at all.
size_t recent_limit(const rek_bt& bt) {
    if (bt.cache_limit == 0 || bt.piece_length == 0) return kRecentPieces;
    const uint64_t by_bytes = std::max<uint64_t>(64, bt.cache_limit / 4 / bt.piece_length);
    return size_t(std::min<uint64_t>(kRecentPieces, by_bytes));
}

/// REKARMA_EVICT_DEBUG=1 makes the eviction pass say what it sees. Off by
/// default; read once, so a read pays a branch instead of a getenv.
bool evict_debug() {
    static const bool on = std::getenv("REKARMA_EVICT_DEBUG") != nullptr;
    return on;
}

/// The read-ahead this session actually uses: --prefetch, or the built-in value.
uint64_t window_ahead(const rek_bt& bt) {
    return bt.prefetch_bytes ? bt.prefetch_bytes : kPrefetchBytes;
}

/// The union of every waiting read's window, as piece ranges. Shared by
/// pump_range (what to fetch) and by the eviction pass (what must not be dropped
/// under a reader that is still waiting for it) — one definition, so the two can
/// never disagree about what is "in use".
std::vector<rek_bt::Range> active_windows(rek_bt& bt) {
    std::vector<rek_bt::Range> windows;
    if (bt.num_pieces == 0 || bt.piece_length == 0) return windows;
    const uint32_t last_piece = bt.num_pieces - 1;
    const uint64_t ahead      = window_ahead(bt);

    std::lock_guard<std::mutex> lock(bt.active_mutex);
    windows.reserve(bt.active.size());
    for (const rek_bt::Range& range : bt.active) {
        if (range.first > last_piece) continue;
        const std::uint64_t end_byte =
            (std::min(range.last, last_piece) + 1ull) * bt.piece_length + ahead;
        const uint32_t window_last = static_cast<uint32_t>(
            std::min<std::uint64_t>(last_piece, end_byte / bt.piece_length));
        windows.push_back(rek_bt::Range{
            range.first > kKeepBehindPieces ? range.first - kKeepBehindPieces : 0,
            window_last,
        });
    }
    return windows;
}

bool in_any_window(const std::vector<rek_bt::Range>& windows, uint32_t piece) {
    for (const rek_bt::Range& window : windows)
        if (piece >= window.first && piece <= window.last) return true;
    return false;
}

bool is_recent(rek_bt& bt, uint32_t piece) {
    std::lock_guard<std::mutex> lock(bt.recent_mutex);
    return bt.recent_set.count(piece) != 0;
}

/// Remember the pieces of a read that just completed, so the next read of the
/// same block (a player re-reading, a second pass over a page) finds them on disk
/// instead of triggering a download. A range longer than the ring keeps its tail:
/// that is the part the reader is closest to.
void note_recent(rek_bt& bt, uint32_t first, uint32_t last) {
    if (last < first) return;
    if (uint64_t(last) - first + 1 > kRecentPieces) first = last - uint32_t(kRecentPieces - 1);

    std::lock_guard<std::mutex> lock(bt.recent_mutex);
    const size_t keep = recent_limit(bt);
    for (uint32_t piece = first;; ++piece) {
        if (bt.recent_set.insert(piece).second) {
            bt.recent.push_back(piece);
            while (bt.recent.size() > keep) {
                bt.recent_set.erase(bt.recent.front());
                bt.recent.pop_front();
            }
        }
        if (piece == last) break;
    }
}

/// Free the blocks of [offset, offset+length) of @p path without changing the
/// file's size: the tree the mount exposes and the lengths the disk layer
/// recorded both stay right, only the bytes stop occupying the SSD.
bool punch_hole(const std::string& path, uint64_t offset, uint64_t length) {
    const int fd = ::open(path.c_str(), O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        if (evict_debug())
            std::fprintf(stderr, "punch: open %s failed: %s\n", path.c_str(), std::strerror(errno));
        return false;
    }
    // fallocate() itself is not declared without _GNU_SOURCE, so the syscall is
    // made directly; the flag values come from <linux/falloc.h>.
    const long rc = ::syscall(SYS_fallocate, fd,
                              int(FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE),
                              (long long)offset, (long long)length);
    const int err = rc == 0 ? 0 : errno;
    ::close(fd);
    if (evict_debug())
        std::fprintf(stderr, "punch: %s @%llu+%llu rc=%ld err=%d\n", path.c_str(),
                     (unsigned long long)offset, (unsigned long long)length, rc, err);
    if (err != 0 && err != EOPNOTSUPP && err != ENOSYS && err != ENOTSUP) {
        std::fprintf(stderr, "rekarma: cannot free %llu bytes of %s: %s\n",
                     (unsigned long long)length, path.c_str(), std::strerror(err));
    }
    return err == 0;
}

/// Cut one piece's bytes out of the cache files that cover it. @c bt.files is
/// ordered by offset (FileStorage lays files end-to-end), so the pieces that
/// overlap are found by a binary search rather than by walking the release.
void punch_piece(rek_bt& bt, uint32_t piece) {
    if (!bt.picker || bt.files.empty()) return;
    const uint64_t start = uint64_t(piece) * bt.piece_length;
    const uint64_t end   = start + bt.picker->piece_size(piece);

    auto it = std::upper_bound(bt.files.begin(), bt.files.end(), start,
                               [](uint64_t value, const rek_bt_file& f) {
                                   return value < uint64_t(f.offset);
                               });
    if (it != bt.files.begin()) --it;

    for (; it != bt.files.end() && uint64_t(it->offset) < end; ++it) {
        const uint64_t file_start = uint64_t(it->offset);
        const uint64_t file_end   = file_start + uint64_t(it->size);
        const uint64_t from = std::max(start, file_start);
        const uint64_t to   = std::min(end, file_end);
        if (to <= from) continue;
        punch_hole(bt.cache_root + "/" + it->path, from - file_start, to - from);
    }
}

/// The inverse of PiecePicker::we_have (piece_picker.cpp): the bytes are gone
/// from the cache, so the piece leaves `have_` and — while it is still wanted —
/// goes back into the rarest-first index. That is what makes the next read of it
/// wait for a real download instead of reading zeros out of the hole.
///
/// Reactor thread only, like every other picker mutation: the fields below are
/// the ones we_have() touches, and the class is single-threaded by design.
void forget_piece(rek_bt& bt, uint32_t piece) {
    PiecePicker& picker = *bt.picker;
    if (piece >= picker.num_pieces_ || !picker.have_.get(piece)) return;

    picker.have_.reset(piece);
    if (picker.num_have_ > 0) --picker.num_have_;
    if (picker.seq_cursor_ > piece) picker.seq_cursor_ = piece;
    picker.downloading_.erase(piece);

    // Undo what we_have() accounted for, then make the piece cold. A forgotten
    // piece that kept its High priority would be requested again immediately, by
    // the picker, with nobody reading it — eviction that never frees anything.
    // DontDownload is what pump_range overrides when a reader comes back.
    if (picker.priority_[piece] != PiecePriority::DontDownload) ++picker.pieces_left_;
    picker.set_piece_priority(piece, PiecePriority::DontDownload);

    // `left` in a tracker announce and the progress line come from these bytes,
    // not from the bitfield: without the subtraction a release read through a
    // capped cache would keep announcing 100 % while holding a few MB.
    const uint64_t size = picker.piece_size(piece);
    bt.torrent->verified_bytes_ =
        bt.torrent->verified_bytes_ > size ? bt.torrent->verified_bytes_ - size : 0;
    if (bt.torrent->state_ == Torrent::State::Seeding) bt.torrent->state_ = Torrent::State::Downloading;
}

/// Bytes the cache files occupy on disk: st_blocks, so a sparse region and a
/// punched hole cost nothing. This is the only number that matches what the
/// user's `df` and `du` will show, and the one a limit has to be enforced against
/// — `have_ * piece_length` counts the pieces the engine kept and misses the
/// blocks of the pieces it abandoned half-downloaded.
///
/// One stat per file, so it is only taken when the gate below says the pass is
/// due, never per read.
uint64_t allocated_bytes(const rek_bt& bt) {
    uint64_t total = 0;
    for (const rek_bt_file& file : bt.files) {
        struct stat st;
        if (::stat((bt.cache_root + "/" + file.path).c_str(), &st) == 0)
            total += uint64_t(st.st_blocks) * 512;
    }
    return total;
}

/// REKARMA_EVICT_DEBUG=1: classify the pieces that actually hold bytes on disk,
/// so a cache that stays over its limit says which kind of piece is holding it.
/// Walks the real extents (SEEK_DATA/SEEK_HOLE), never the picker's opinion.
void dump_cache_state(rek_bt& bt) {
    if (!evict_debug() || bt.files.empty()) return;
    static auto last = std::chrono::steady_clock::now() - std::chrono::seconds(5);
    const auto now = std::chrono::steady_clock::now();
    if (now - last < std::chrono::seconds(1)) return;
    last = now;

    unsigned have = 0, high = 0, normal = 0, parked = 0, busy = 0;
    for (const rek_bt_file& file : bt.files) {
        const std::string path = bt.cache_root + "/" + file.path;
        const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        const int64_t size = file.size;
        int64_t off = 0;
        while (off < size) {
            const off_t data = ::lseek(fd, off, SEEK_DATA);
            if (data < 0) break;
            const off_t hole = ::lseek(fd, data, SEEK_HOLE);
            const int64_t end = hole < 0 ? size : std::min<int64_t>(hole, size);
            for (int64_t pos = data; pos < end; pos += bt.piece_length) {
                const uint32_t piece = uint32_t((uint64_t(file.offset) + uint64_t(pos)) / bt.piece_length);
                if (bt.picker->have_piece(piece)) { ++have; continue; }
                if (bt.picker->downloading_.find(piece) != bt.picker->downloading_.end()) { ++busy; continue; }
                switch (bt.picker->piece_priority(piece)) {
                    case PiecePriority::High: ++high; break;
                    case PiecePriority::Normal: ++normal; break;
                    default: ++parked; break;
                }
            }
            off = end;
        }
        ::close(fd);
    }
    std::fprintf(stderr, "cache state: have %u, high %u, normal %u, parked %u, downloading %u\n",
                 have, high, normal, parked, busy);
}

/// Bring the cache back under its limit, measured.
///
/// Two kinds of bytes are in the cache and both count against the limit:
///
///   - pieces the picker has (`have_`), which a re-read of the same block wants;
///   - blocks written for pieces that were abandoned half-downloaded when their
///     window went away. Those are garbage — pump_range parks the piece as
///     DontDownload, so nothing will ever complete them — and they are why a
///     cache measured in `have_ * piece_length` alone grows past its limit.
///
/// Nothing here is estimated. A pass punches candidates and then stats the cache
/// files: `st_blocks` is the only number that matches what the user's `df` says,
/// and an eviction pass that trusts its own arithmetic keeps "freeing" pieces
/// that are already holes while the real data further along is never reached.
///
/// The pass runs on the reactor right after a read handed its bytes out. A piece
/// is forgotten and its hole punched in the same callback: refill() is the only
/// thing that can ask a peer for a piece and it runs on this thread too, so
/// nothing can re-download a piece between the two, and no reader can ever see a
/// hole that `have_` still claims is data.
void evict_to_limit(rek_bt& bt) {
    if (bt.cache_limit == 0 || !bt.picker || bt.piece_length == 0 || bt.num_pieces == 0) return;
    if (bt.files.empty()) return;

    // Statting the release's files is cheap once and wasteful per read, so the
    // number is sampled: at most a few times a second. Between samples the cache
    // can overshoot by what the swarm delivers in that time.
    const auto now = std::chrono::steady_clock::now();
    const bool due = bt.cache_bytes_at == std::chrono::steady_clock::time_point{} ||
                     now - bt.cache_bytes_at >= std::chrono::milliseconds(250);
    if (!due) return;
    bt.cache_bytes_at = now;
    bt.cache_bytes    = allocated_bytes(bt);
    if (bt.cache_bytes <= bt.cache_limit) return;

    const uint64_t need  = bt.cache_bytes - bt.cache_target;
    const uint32_t total = bt.num_pieces;
    // How many candidates a pass may look at: enough to cover what has to go,
    // with slack for the pieces that turn out to be holes already. Capped, so a
    // read on a 500 000-piece torrent cannot turn into a full scan.
    uint64_t wanted = need / bt.piece_length + 64;
    const uint32_t budget = static_cast<uint32_t>(std::min<uint64_t>(wanted, std::min<uint32_t>(total, 65536)));

    on_reactor(*bt.client, [&] {
        const std::vector<rek_bt::Range> windows = active_windows(bt);

        // Pass 1 — the pieces the engine kept. These are the ones a reader may
        // want again, so the recently-read ones go last, and they are the only
        // ones whose removal has to be told to the picker.
        uint32_t cold = 0, looked = 0;
        while (cold < budget && looked < budget * 4) {
            const uint32_t piece = bt.evict_cursor;
            bt.evict_cursor = (piece + 1) % total;
            ++looked;
            if (!bt.picker->have_piece(piece)) continue;
            if (in_any_window(windows, piece)) continue;
            if (is_recent(bt, piece)) continue;
            forget_piece(bt, piece);
            punch_piece(bt, piece);
            ++cold;
        }

        // Pass 2 — leftovers with no `have_` bit that pump_range has parked:
        // nothing will ever complete them, so every byte they hold is garbage.
        // Block progress is no reason to keep it — librats re-creates a progress
        // entry when a peer finally answers a request for a window that has since
        // closed, and that residue is exactly what makes a cache measured only by
        // `have_` grow past its limit. The entry is dropped with the bytes; the
        // piece is fetched in full again if a reader ever comes back to it.
        uint32_t orphans = 0;
        uint64_t measured = allocated_bytes(bt);
        if (measured > bt.cache_target) {
            uint32_t seen = 0;
            while (orphans < budget / 2 && seen < budget * 2) {
                const uint32_t piece = bt.evict_cursor;
                bt.evict_cursor = (piece + 1) % total;
                ++seen;
                if (bt.picker->have_piece(piece)) continue;
                if (in_any_window(windows, piece)) continue;
                if (bt.picker->piece_priority(piece) != PiecePriority::DontDownload) continue;
                bt.picker->downloading_.erase(piece);
                punch_piece(bt, piece);
                ++orphans;
            }
            measured = allocated_bytes(bt);
        }

        bt.cache_bytes = measured;
        dump_cache_state(bt);
        if (evict_debug())
            std::fprintf(stderr, "evict: %u cold (%u looked) + %u orphan punched, cache %llu of %llu\n",
                         cold, looked, orphans, (unsigned long long)bt.cache_bytes,
                         (unsigned long long)bt.cache_limit);
    });
}


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
        // which is exactly "playback stops after seeking". The eviction pass uses
        // the same list, so what a read is waiting for is never dropped under it.
        const std::vector<rek_bt::Range> windows = active_windows(bt);
        auto in_window = [&](uint32_t piece) { return in_any_window(windows, piece); };

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

/// A piece a reader is waiting for has missed its deadline: ask one more peer for
/// each of its blocks that only one peer is currently on. This is BitTorrent's
/// end-game trade — some bytes are fetched twice — spent on the few pieces that
/// stand between the reader and the next second of video, and only while they are
/// late.
///
/// The engine already handles the duplicates: the winner's block arrives, it
/// cancels the other request and takes the slot back, so nothing is left
/// double-counted. `by_rate` is ordered fastest first, so the copy goes to a peer
/// that has been delivering.
void duplicate_piece(rek_bt& bt, uint32_t piece, const std::vector<PeerConnection*>& by_rate) {
    auto it = bt.picker->downloading_.find(piece);
    if (it == bt.picker->downloading_.end()) return;
    PiecePicker::DownloadingPiece& dp = it->second;
    Torrent& torrent = *bt.torrent;

    for (uint32_t b = 0; b < dp.blocks.size(); ++b) {
        PiecePicker::Block& block = dp.blocks[b];
        if (block.state != BlockState::Requested || block.peers.size() != 1) continue;
        const void* owner = block.peers.front();
        for (PeerConnection* pc : by_rate) {
            if (static_cast<const void*>(pc) == owner) continue;
            if (!pc->peer_bitfield().get(piece)) continue;
            int& outstanding = torrent.outstanding_[pc];
            if (outstanding >= int(bt.pipeline_blocks)) continue;
            const PieceBlock pb{piece, b};
            bt.picker->mark_requested(pb, pc);
            pc->send_request(piece, b * kBlockSize, bt.picker->block_size(piece, b));
            ++outstanding;
            ++bt.duplicate_blocks;
            break;
        }
    }
}

/// Block requests kept in flight per peer, how often the queues are topped up, and
/// how long a piece a reader is waiting for may sit before its blocks are asked
/// for a second time.
///
/// librats asks for kPipelineDepth = 16 blocks (256 KiB) per peer and only refills
/// when one arrives, so a single peer is capped at 256 KiB / RTT: 1.7 MB/s to a
/// peer 150 ms away, whatever that peer's own bandwidth is. Filling a 100 Mbit/s
/// line would take six fast seeders, which a film release rarely offers, and the
/// read stalls while it waits.
///
/// A deeper queue has to be driven from here because the constant lives in the
/// vendored archive. It is also not enough on its own: a queue of N blocks handed
/// to a slow peer makes *that peer* the piece's completion time, and the reader
/// waits for the whole piece. So the depth follows each peer's measured rate, and
/// a piece the reader is waiting on that misses its deadline asks for its
/// outstanding blocks a second time from somebody faster.
constexpr int kRefillChunk = 32;
/// The floor: a peer that has shown nothing gets a few blocks as a probe, not the
/// 16 it used to get even while delivering nothing — 25 such peers each holding 16
/// blocks of the reader's piece is a piece that never completes.
constexpr int kMinPeerBlocks = 4;
constexpr std::chrono::milliseconds kLatePiece{700};
constexpr std::chrono::milliseconds kRefillInterval{20};

/// How deep this peer's queue should be: one second of what it has proven it can
/// deliver, so a slow seeder holds a small slice of a piece instead of all of it,
/// and never more than the session's --pipeline.
int peer_depth(const rek_bt& bt, const rek_bt::PeerPace& pace) {
    const int depth = int(pace.rate / double(kBlockSize));
    return std::clamp(depth, kMinPeerBlocks, int(bt.pipeline_blocks));
}

/// Ask every unchoked peer for more blocks, deeper for the ones that are
/// delivering. Reactor thread only — it walks peers_ and mutates the picker, like
/// librats' refill().
///
/// Deliberately silent when nobody is reading: an idle mount must not pull the
/// release in the background (librats' own refill covers the keepalive piece).
void deep_refill(rek_bt& bt) {
    if (bt.pipeline_blocks == 0 || !bt.torrent || !bt.picker || !bt.disk) return;
    Torrent& torrent = *bt.torrent;
    if (!torrent.running_) return;

    std::vector<rek_bt::Range> reading;
    {
        std::lock_guard<std::mutex> lock(bt.active_mutex);
        reading = bt.active;
    }
    if (reading.empty()) {
        // Nobody is reading: keep the measured paces (a pause or a seek should not
        // make every peer look new) but drop the deadlines and the sample clock, so
        // the first pass after the pause does not divide a minute by nothing.
        bt.late.clear();
        bt.pace_at = std::chrono::steady_clock::time_point{};
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    const double dt = bt.pace_at == std::chrono::steady_clock::time_point{}
        ? 0.0 : std::chrono::duration<double>(now - bt.pace_at).count();
    bt.pace_at = now;

    // Drop what belongs to connections the torrent has let go: the pointers are
    // only valid while they are in peers_, and a recycled address must not
    // inherit somebody else's rate.
    for (auto it = bt.pace.begin(); it != bt.pace.end();) {
        if (std::find(torrent.peers_.begin(), torrent.peers_.end(), it->first) == torrent.peers_.end())
            it = bt.pace.erase(it);
        else
            ++it;
    }

    // Measure each peer, then ask the fast ones first: a block freed by a snub or
    // by duplicate_piece below must land on a peer that will deliver it.
    std::vector<std::pair<double, PeerConnection*>> by_rate;
    for (PeerConnection* pc : torrent.peers_) {
        if (!pc || pc->closed()) continue;
        rek_bt::PeerPace& pace = bt.pace[pc];
        // The engine keeps a per-peer byte count for its choker (recent_down_), 
        // reset every ~10 s with the choke round. A counter that went backwards is
        // that reset, not a negative rate: rebaseline and keep the last estimate.
        const uint64_t bytes = torrent.recent_down_[pc];
        if (dt > 0.0 && bytes >= pace.bytes) {
            const double measured = double(bytes - pace.bytes) / dt;
            // A peer that speeds up is believed at once; one that slows down is
            // given the benefit of the doubt for a few passes.
            pace.rate = measured > pace.rate ? measured : pace.rate * 0.75 + measured * 0.25;
        }
        pace.bytes = bytes;
        if (pc->peer_choking() || !pc->am_interested()) continue;
        by_rate.emplace_back(pace.rate, pc);
    }
    std::sort(by_rate.begin(), by_rate.end(),
              [](const auto& a, const auto& b) { return a.first > b.first; });
    std::vector<PeerConnection*> order;
    order.reserve(by_rate.size());
    for (const auto& entry : by_rate) order.push_back(entry.second);

    // Peers this slow do not get blocks the reader is waiting on: a piece completes
    // when its *last* block arrives, so one peer at a few KB/s owning a corner of it
    // is the whole stall. They still fetch the pieces further ahead, which have no
    // deadline yet. The cut is relative to the best peer, so a swarm where everyone
    // is slow is not starved.
    const double fast_cutoff = by_rate.empty() ? 0.0 : by_rate.front().first * 0.25;
    auto in_readers_way = [&reading](std::uint32_t piece) {
        for (const auto& range : reading) {
            if (piece >= range.first && piece <= range.last) return true;
        }
        return false;
    };

    // Same backpressure the engine applies: a fast swarm must not grow the write
    // queue without bound. Requesting resumes on the next pass as it drains.
    if (bt.disk->queued_write_bytes() <= Torrent::kDiskWriteHighWater) {
        for (PeerConnection* pc : order) {
            rek_bt::PeerPace& pace = bt.pace[pc];
            int& outstanding = torrent.outstanding_[pc];
            const int depth = peer_depth(bt, pace);
            int budget = depth - outstanding;
            if (budget <= 0) continue;
            if (budget > kRefillChunk) budget = kRefillChunk;
            const bool slow = pace.rate < fast_cutoff;

            const bool idle = outstanding == 0;
            const std::vector<PieceBlock> blocks =
                bt.picker->pick_blocks(pc->peer_bitfield(), budget, pc);
            for (const PieceBlock& b : blocks) {
                if (slow && in_readers_way(b.piece)) continue;
                bt.picker->mark_requested(b, pc);
                pc->send_request(b.piece, b.block * kBlockSize, bt.picker->block_size(b.piece, b.block));
                ++outstanding;
            }
            // The engine's stall clock: a peer that holds requests and delivers
            // nothing is snubbed after kRequestTimeout, which frees its blocks for
            // somebody who is actually sending.
            if (idle && outstanding > 0) torrent.request_time_[pc] = now;
        }
    }

    // The pieces a reader is actually blocked on, and only those: a piece that
    // takes longer than kLatePiece gets its outstanding blocks asked for from one
    // more peer. Whichever copy arrives first wins and the engine cancels the
    // other, so a single slow seeder can no longer decide when playback resumes.
    for (const rek_bt::Range& range : reading) {
        const uint32_t last = std::min(range.last, bt.num_pieces - 1);
        for (uint32_t piece = range.first; piece <= last; ++piece) {
            if (bt.picker->have_piece(piece)) {
                bt.late.erase(piece);
                continue;
            }
            const auto it = bt.late.find(piece);
            if (it == bt.late.end()) {
                bt.late.emplace(piece, now);
                continue;
            }
            if (now - it->second < kLatePiece) continue;
            it->second = now;
            duplicate_piece(bt, piece, order);
        }
    }
    // Forget the pieces no read is waiting for any more.
    for (auto it = bt.late.begin(); it != bt.late.end();) {
        const uint32_t piece = it->first;
        const bool still_read = std::any_of(reading.begin(), reading.end(), [piece](const rek_bt::Range& r) {
            return piece >= r.first && piece <= r.last;
        });
        it = still_read ? std::next(it) : bt.late.erase(it);
    }
}


void schedule_refill(rek_bt& bt);

/// Arm the refill timer on the reactor. One-shot timers that re-arm themselves
/// (the reactor has no repeating timer), stopped by `refill_alive`.
void schedule_refill(rek_bt& bt) {
    if (!bt.refill_alive->load() || !bt.client) return;
    std::shared_ptr<std::atomic<bool>> alive = bt.refill_alive;
    rek_bt* self = &bt;
    bt.client->reactor().schedule(kRefillInterval, [self, alive] {
        if (!alive->load()) return;
        deep_refill(*self);
        schedule_refill(*self);
    });
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

/// Everything the magnet and the .torrent entry points share: the cache
/// directory, the client and its DHT. What differs between them is only how the
/// info dict is obtained — read from the file, or fetched from peers (BEP 9).
rek_bt* start_session(const char* cache_dir, uint16_t port, int enable_dht, const rek_bt_config* cfg,
                      char* err, size_t err_len) {
    std::error_code ec;
    std::filesystem::create_directories(cache_dir, ec);
    if (ec) {
        set_error(err, err_len, "cannot create the cache directory");
        return nullptr;
    }

    auto bt = std::make_unique<rek_bt>();

    Client::Config config;
    config.listen_port   = port;
    config.download_path = cache_dir;
    bt->client = std::make_unique<Client>(config);

    // The cache budget. A limit below 32 MiB would evict faster than a read can
    // fetch, and a target at the limit itself would evict one piece per read for
    // ever, so it is held a tenth below the cap: a single pass makes room for the
    // next few reads instead of exactly one.
    bt->cache_root     = cache_dir;
    bt->cache_limit    = cfg ? cfg->cache_limit : 0;
    bt->prefetch_bytes = cfg ? cfg->prefetch : 0;
    bt->pipeline_blocks = cfg ? cfg->pipeline : 0;
    bt->refill_alive   = std::make_shared<std::atomic<bool>>(true);
    if (bt->cache_limit != 0) {
        constexpr uint64_t kMinLimit = 32ull * 1024 * 1024;
        if (bt->cache_limit < kMinLimit) bt->cache_limit = kMinLimit;
        bt->cache_target = bt->cache_limit - bt->cache_limit / 10;

        // A window that is a large share of the budget is wasted budget: what a
        // read does not get to is downloaded, abandoned and punched again. The
        // read-ahead is therefore held to a sixteenth of the cache, which leaves
        // the default 128 MiB untouched on any cache of 2 GB or more and keeps a
        // deliberately tiny cache (a test, a 200 MB container) usable.
        const uint64_t room = std::max<uint64_t>(1024 * 1024, bt->cache_limit / 16);
        const uint64_t ahead = bt->prefetch_bytes ? bt->prefetch_bytes : kPrefetchBytes;
        bt->prefetch_bytes = std::min(ahead, room);
    }

    // A magnet has no peer list of its own beyond trackers, and a torrent with
    // no trackers would never find anything: one DHT client, bootstrapped and
    // handed to the session, is the peer source. Failure is not fatal —
    // trackers and --connect peers still work.
    if (enable_dht) {
        bt->dht = std::make_unique<DhtClient>(0);
        if (bt->dht->start()) {
            bt->dht->bootstrap(DhtClient::get_default_bootstrap_nodes());
            bt->client->set_external_dht(bt->dht.get());
        }
    }

    bt->client->start();
    return bt.release();
}

/// One line for the "still waiting" message: what the blocks of the reader's
/// pieces are doing and how many peers could actually deliver them, so a stall on
/// a slow seeder can be told apart from a swarm that has nothing left to give.
/// Runs one reactor pass per call, i.e. only when a read is already stuck.
void describe_stall(rek_bt& bt, uint32_t first, uint32_t last, char* out, size_t len) {
    if (!bt.client || !bt.picker || !bt.torrent) {
        std::snprintf(out, len, "no picker yet");
        return;
    }
    unsigned none = 0, requested = 0, writing = 0, unchoked = 0;
    std::vector<std::string> owners;   // "ip:port" of a peer holding blocks of the range
    std::vector<unsigned>    held;     // how many blocks that peer holds
    std::vector<double>      pace_rates;  // its measured pace, blocks per second

    on_reactor(*bt.client, [&] {
        for (PeerConnection* pc : bt.torrent->peers_) {
            if (pc && pc->am_interested() && !pc->peer_choking()) ++unchoked;
        }
        for (uint32_t piece = first; piece <= std::min(last, bt.num_pieces - 1); ++piece) {
            if (bt.picker->have_piece(piece)) continue;
            const auto it = bt.picker->downloading_.find(piece);
            if (it == bt.picker->downloading_.end()) {
                ++none;
                continue;
            }
            for (const PiecePicker::Block& block : it->second.blocks) {
                if (block.state == BlockState::None) { ++none; continue; }
                if (block.state == BlockState::Writing) { ++writing; continue; }
                if (block.state != BlockState::Requested) continue;
                ++requested;
                for (const void* owner : block.peers) {
                    auto* pc = static_cast<PeerConnection*>(const_cast<void*>(owner));
                    char label[64];
                    std::snprintf(label, sizeof label, "%s:%u", pc->remote_ip().c_str(), pc->remote_port());
                    auto found = std::find(owners.begin(), owners.end(), std::string(label));
                    if (found != owners.end()) {
                        ++held[size_t(found - owners.begin())];
                        continue;
                    }
                    owners.emplace_back(label);
                    held.push_back(1);
                    const auto pace = bt.pace.find(owner);
                    pace_rates.push_back(pace == bt.pace.end() ? 0.0 : pace->second.rate);
                }
            }
        }
    });

    std::snprintf(out, len, "blocks none %u requested %u writing %u; %u unchoked; dups %llu;",
                  none, requested, writing, unchoked, (unsigned long long)bt.duplicate_blocks);
    // Which peers are sitting on the reader's blocks, and at what pace.
    std::vector<size_t> by_share(owners.size());
    for (size_t i = 0; i < by_share.size(); ++i) by_share[i] = i;
    std::sort(by_share.begin(), by_share.end(), [&](size_t a, size_t b) { return held[a] > held[b]; });
    for (size_t i = 0; i < std::min<size_t>(by_share.size(), 3); ++i) {
        const size_t at = by_share[i];
        char part[112];
        std::snprintf(part, sizeof part, " %u@%s(%.0f b/s)", held[at], owners[at].c_str(), pace_rates[at]);
        strncat(out, part, len - strlen(out) - 1);
    }
}

} // namespace

extern "C" {

rek_bt* rek_bt_open(const char* magnet_uri, const char* cache_dir, uint16_t port, int enable_dht,
                    const rek_bt_config* cfg, char* err, size_t err_len) {
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

    rek_bt* bt = start_session(cache_dir, port, enable_dht, cfg, err, err_len);
    if (!bt) return nullptr;

    bt->hash = parsed->info_hash;
    bt->torrent = bt->client->add_magnet(magnet, cache_dir);
    if (!bt->torrent) {
        rek_bt_close(bt);
        set_error(err, err_len, "librats refused the magnet link");
        return nullptr;
    }
    return bt;
}

/// Mount the release a .torrent file describes. The metadata is in the file, so
/// there is no BEP 9 wait and no swarm needed to browse it.
rek_bt* rek_bt_open_torrent(const char* torrent_path, const char* cache_dir, uint16_t port,
                            int enable_dht, const rek_bt_config* cfg, char* err, size_t err_len) {
    if (!torrent_path || !cache_dir) {
        set_error(err, err_len, "a .torrent path and a cache directory are required");
        return nullptr;
    }

    TorrentParseError parse_error;
    auto info = TorrentInfo::from_file(torrent_path, &parse_error);
    if (!info) {
        // The parser's own message says more than an errno would ("missing info
        // dictionary", "unexpected end of data"), so it is passed through — with
        // the path, because the parser cannot know what the user typed.
        char msg[512];
        std::snprintf(msg, sizeof msg, "%s: %s", torrent_path,
                      parse_error.message.empty() ? "not a readable .torrent" : parse_error.message.c_str());
        set_error(err, err_len, msg);
        return nullptr;
    }

    rek_bt* bt = start_session(cache_dir, port, enable_dht, cfg, err, err_len);
    if (!bt) return nullptr;

    bt->hash = info->info_hash();
    bt->torrent = bt->client->add_torrent(*info, cache_dir);
    if (!bt->torrent) {
        rek_bt_close(bt);
        set_error(err, err_len, "librats refused the torrent");
        return nullptr;
    }
    return bt;
}

/// What an announce needs from the session, for src/tracker.zig: the engine
/// cannot reach an https tracker at all, so the caller announces instead and
/// feeds the peers back through rek_bt_add_peer.
size_t rek_bt_tracker_count(rek_bt* bt) {
    if (!bt || !bt->torrent) return 0;
    return bt->torrent->info_.all_trackers().size();
}

/// Writes tracker @p index into @p buf (NUL-terminated) and returns its length,
/// or 0 when there is no such tracker. A URL that does not fit is truncated.
size_t rek_bt_tracker_url(rek_bt* bt, size_t index, char* buf, size_t len) {
    if (!bt || !bt->torrent || !buf || len == 0) return 0;
    const std::vector<std::string> urls = bt->torrent->info_.all_trackers();
    if (index >= urls.size()) return 0;
    std::snprintf(buf, len, "%s", urls[index].c_str());
    return std::strlen(buf);
}

/// 40 hex chars + NUL for the info-hash and for the peer id, in that order.
void rek_bt_identity(rek_bt* bt, char* info_hash_hex, char* peer_id_hex, size_t len) {
    if (info_hash_hex && len) info_hash_hex[0] = 0;
    if (peer_id_hex && len) peer_id_hex[0] = 0;
    if (!bt || !bt->client || !info_hash_hex || !peer_id_hex || len < 41) return;

    const InfoHash& hash = bt->torrent ? bt->torrent->info_hash() : bt->hash;
    const PeerId&  peer_id = bt->client->peer_id();
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < hash.size(); ++i) {
        info_hash_hex[i * 2]     = digits[hash[i] >> 4];
        info_hash_hex[i * 2 + 1] = digits[hash[i] & 0x0f];
        peer_id_hex[i * 2]       = digits[peer_id[i] >> 4];
        peer_id_hex[i * 2 + 1]   = digits[peer_id[i] & 0x0f];
    }
    info_hash_hex[hash.size() * 2] = 0;
    peer_id_hex[peer_id.size() * 2] = 0;
}

uint16_t rek_bt_listen_port(rek_bt* bt) {
    return bt && bt->client ? bt->client->listen_port() : 0;
}

void rek_bt_close(rek_bt* bt) {
    if (!bt) return;
    // Stop the refill timer before the reactor thread is joined: the callback
    // captures the session, so it must not run after stop() returns and
    // `delete bt` frees it. The flag is checked first in the callback; stop()
    // then joins the thread, so no callback is in flight afterwards.
    if (bt->refill_alive) bt->refill_alive->store(false);
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
                // The deeper per-peer queue starts here, not earlier: there is no
                // picker to feed before the metadata lands.
                if (bt->pipeline_blocks != 0 && !bt->refill_timer_armed) {
                    bt->refill_timer_armed = true;
                    schedule_refill(*bt);
                }
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

/// The cap this session runs under, in bytes (0 = unbounded). Reported so the
/// banner can say what is being enforced instead of leaving the user to guess.
uint64_t rek_bt_cache_limit(rek_bt* bt) { return bt ? bt->cache_limit : 0; }

/// What the cache occupies on disk right now, holes and sparse regions excluded
/// — the same number `du` would print, not the picker's idea of what it kept.
uint64_t rek_bt_cache_bytes(rek_bt* bt) {
    if (!bt || bt->files.empty()) return 0;
    bt->cache_bytes = allocated_bytes(*bt);
    return bt->cache_bytes;
}

/// Bytes an unprivileged process can still write to the filesystem holding
/// @p path, or 0 when it cannot be asked. This is what "cache limit auto" is
/// computed from: the limit has to follow the disk the cache is actually on, not
/// a constant picked for a desktop.
uint64_t rek_bt_free_bytes(const char* path) {
    if (!path) return 0;
    struct statvfs vfs;
    if (::statvfs(path, &vfs) != 0) return 0;
    return uint64_t(vfs.f_bavail) * uint64_t(vfs.f_frsize);
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
            char detail[192];
            describe_stall(*bt, first, last, detail, sizeof detail);
            std::fprintf(stderr, "rekarma: waiting for pieces %u..%u (%u missing, %lld ms): %s\n",
                         first, last, missing,
                         (long long)std::chrono::duration_cast<std::chrono::milliseconds>(now - started).count(),
                         detail);
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

    // The read is done, so the pieces it touched are worth keeping (a re-read of
    // the same block is common) and everything cold can go: this is where a
    // cache limit is actually enforced, once per read instead of on a timer that
    // would keep running on an idle mount.
    note_recent(*bt, first, last);
    evict_to_limit(*bt);
    return static_cast<int64_t>(written);
}

} // extern "C"
