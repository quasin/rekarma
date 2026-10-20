#pragma once

/*
 * Local patch to librats, NOT an upstream file.
 *
 * Build/source: librats-linux-x64-3.0.2.zip
 *   https://github.com/librats/librats/releases/download/3.0.2/librats-linux-x64-3.0.2.zip
 *   sha256 195544a0f9a7b6f9465ed5c551674553976d8df962635973327583a841a16974
 *
 * librats generates this header from features.h.in at CMake time and every
 * public header reaches it through librats/util/rats_export.h — but the 3.0.2
 * release archive does not ship it, so the shipped headers cannot be included
 * as-is. This file is that missing piece, hand-written to match the build the
 * archive's librats.a was compiled with (checked against its exported symbols:
 * DHT + bittorrent search entry points such as rats_enable_bittorrent and
 * rats_bt_add_magnet are present, so those macros are defined).
 *
 * It is STATIC-build settings only: RATS_EXPORT_DLL / RATS_IMPORT_DLL belong to
 * the shared (DLL) build and must stay undefined for librats.a.
 *
 * scripts/fetch-librats.sh copies this file to
 * vendor/librats/include/librats/util/features.h after unpacking the release —
 * the archive's own header tree is never committed.
 */

/* Search features (DHT discovery + bittorrent search API) are compiled in. */
#define RATS_SEARCH_FEATURES 1

/* Storage support is compiled in. */
#define RATS_STORAGE 1
