#pragma once

/*
 * Every C header the project needs, in one place: src/main.zig imports the
 * translate-c module built from this file as `@import("c")`.
 *
 * Zig 0.17 removed inline @cImport, so C headers are translated into a Zig
 * module in build.zig (b.addTranslateC) and imported by name.
 */

#include <librats/bindings/rats.h>
