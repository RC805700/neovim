#!/usr/bin/env bash
set -euo pipefail

# Phase 0 build script for Odin-port of Neovim.
#
# Builds the existing C code as a static library, then links an Odin entry point
# against it to produce a working nvim binary.
#
# Usage:
#   ./src/odin/build.sh              # debug build
#   ./src/odin/build.sh release      # release build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_TYPE="${1:-debug}"

if [ "$BUILD_TYPE" = "release" ]; then
    CMAKE_BUILD_TYPE=Release
    ODIN_OPT="-o:speed"
else
    CMAKE_BUILD_TYPE=Debug
    ODIN_OPT="-debug"
fi

echo "=== Phase 0: Building libnvim.a (C static library) ==="
cmake -S "$ROOT" -B "$ROOT/build" -G Ninja -D CMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE"

cmake --build "$ROOT/build" --target libnvim

echo ""
echo "=== Phase 0: Building nvim_odin (Odin entry point) ==="
odin build "$ROOT/src/odin" \
    $ODIN_OPT \
    -out:"$ROOT/build/bin/nvim_odin" \
    -extra-linker-flags:"-rdynamic \
        -L$ROOT/build/lib \
        -L/usr/lib -L/usr/lib/x86_64-linux-gnu \
        -lnvim \
        /usr/lib/lua/5.1/lpeg.so \
        -luv -lluajit-5.1 -lluv -ltree-sitter -lutf8proc -lunibilium \
        -lm -lnsl -ltirpc -ldl -lpthread"

echo ""
echo "=== Success! ==="
echo "Binary: $ROOT/build/bin/nvim_odin"
"$ROOT/build/bin/nvim_odin" --version
