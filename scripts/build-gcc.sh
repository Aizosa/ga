#!/bin/sh
# Build GNU GCC 16.2.0 for x86_64-apple-darwin on a GitHub Actions
# macOS 26 Intel runner, with NLS enabled.
#
# Run inside the runner (macOS). Called from .github/workflows/build-gcc.yml.
#
# Outputs:
#   $PREFIX                 installed GCC tree (uploaded as artifact)
#   $WORKSPACE/gcc-16.2.0-x86_64-darwin26-nls.tar.gz  packaged bundle
set -euo pipefail

GCC_VERSION="16.2.0"
# First run: a reduced but stable set to prove the whole build, packaging
# and artifact pipeline on the Intel runner. ada needs a
# pre-existing GNAT (absent on runners) and gccgo is largely unmaintained;
# both are deferred. jit is deferred too: on macOS the GCC safe-ctype.h macros
# clash with the SDK libc++ headers pulled in by the JIT C++ sources (upstream
# PR 111632). See README.md -> "Language set".
LANGUAGES="c,c++,fortran,objc,obj-c++"

WORKSPACE="${GITHUB_WORKSPACE:-$HOME}"
PREFIX="$WORKSPACE/gcc-install"
SRC="$WORKSPACE/src/gcc-$GCC_VERSION"
BUILD="$SRC/build"
BUNDLE="$WORKSPACE/gcc-$GCC_VERSION-x86_64-darwin26-nls.tar.gz"

# ---- Prerequisite versions pinned by this GCC release ---------------------
GMP_VER="6.3.0"
MPFR_VER="4.2.2"
MPC_VER="1.3.1"
ISL_VER="0.24"

GNU_MIRROR="https://ftp.gnu.org/gnu"
ISL_URL="https://libisl.sourceforge.io/isl-${ISL_VER}.tar.bz2"

log() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
log "Environment self-check"
ARCH="$(uname -m)"
echo "arch=$ARCH  $(sw_vers 2>/dev/null | tr '\n' ' ')"
echo "ncpu=$(sysctl -n hw.ncpu)  mem=$(sysctl -n hw.memsize)"
df -h / || true
if [ "$ARCH" != "x86_64" ]; then
  echo "ERROR: this workflow must run on the x64 runner (macos-26-intel); got $ARCH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
log "Install runtime prerequisites via Homebrew"
# gmp/mpfr/mpc/isl are built in-tree below; gettext (libintl), GNU make
# and texinfo come from Homebrew. macOS /usr/bin/make is BSD make and
# cannot build GCC, so we use the Homebrew gmake.
brew update >/dev/null || true
brew install gettext texinfo make
GETTEXT_PREFIX="$(brew --prefix gettext)"
export MAKE="gmake"
export CC=clang
export CXX=clang++
echo "gettext prefix=$GETTEXT_PREFIX  make=$(gmake --version | head -1)"

# ---------------------------------------------------------------------------
log "Download GCC $GCC_VERSION source"
mkdir -p "$WORKSPACE/src"
cd "$WORKSPACE/src"
if [ ! -d "$SRC" ]; then
  curl -fSL -o "gcc-$GCC_VERSION.tar.xz" \
    "$GNU_MIRROR/gcc/gcc-$GCC_VERSION/gcc-$GCC_VERSION.tar.xz"
  # GCC publishes a GPG .sig, not a standalone sha256 file; the source is
  # fetched over HTTPS from the official GNU mirror on the runner.
  tar xf "gcc-$GCC_VERSION.tar.xz"
fi

# ---------------------------------------------------------------------------
log "Fetch in-tree prerequisite libraries"
cd "$SRC"
fetch_extract() {
  name="$1"; url="$2"
  archive="${name}.tar.${3}"
  if [ ! -d "${name}" ]; then
    echo "fetch $name"
    curl -fSL -o "$archive" "$url"
    tar xf "$archive"
  fi
}
fetch_extract "gmp-${GMP_VER}"   "$GNU_MIRROR/gmp/gmp-${GMP_VER}.tar.bz2"  "bz2"
fetch_extract "mpfr-${MPFR_VER}" "$GNU_MIRROR/mpfr/mpfr-${MPFR_VER}.tar.bz2" "bz2"
fetch_extract "mpc-${MPC_VER}"   "$GNU_MIRROR/mpc/mpc-${MPC_VER}.tar.gz"     "gz"
fetch_extract "isl-${ISL_VER}"   "$ISL_URL"                                  "bz2"

# Symlinks expected by the GCC build (same convention as download_prerequisites)
ln -sfn "gmp-${GMP_VER}"   gmp
ln -sfn "mpfr-${MPFR_VER}" mpfr
ln -sfn "mpc-${MPC_VER}"   mpc
ln -sfn "isl-${ISL_VER}"   isl

# Free disk space: runner disks are small, drop the archives after extraction.
rm -f "$SRC"/*.tar.* "$WORKSPACE/src"/*.tar.*

# ---------------------------------------------------------------------------
log "Configure (out-of-tree)"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# Xcode 11+ ships no /usr/include; headers live in the SDK. A native GCC
# build on Darwin must be pointed at the SDK explicitly, otherwise
# fixinc probes the nonexistent /usr/include and fails (GCC bug 90834).
SDK_PATH="$(xcrun --show-sdk-path)"
export SDKROOT="$SDK_PATH"
echo "sdk=$SDK_PATH"

# libsanitizer's sanitizer_mac.cpp pulls in the XNU SDK mach headers, whose
# xnu_static_assert_struct_size macros GCC cannot parse; skip the sanitizer
# runtimes (ASan/UBSan/TSan) -- they are not needed for ordinary builds.
../configure \
  --prefix="$PREFIX" \
  --with-sysroot="$SDK_PATH" \
  --enable-languages="$LANGUAGES" \
  --enable-nls \
  --disable-bootstrap \
  --with-libintl-prefix="$GETTEXT_PREFIX" \
  --with-system-zlib \
  --disable-multilib \
  --disable-lto \
  --disable-libsanitizer \
  --enable-checking=release \
  --program-suffix=-16 \
  CPPFLAGS="-I$GETTEXT_PREFIX/include" \
  LDFLAGS="-L$GETTEXT_PREFIX/lib"

# Record the resolved NLS decision for the verification step.
grep -E "^ENABLE_NLS|^HAVE_LIBINTL" Makefile || true

# ---------------------------------------------------------------------------
# --disable-bootstrap: single-stage build with the host clang, no stage2/3
# self-hosting cycle. The product skips the bootstrap consistency check but
# is a complete, working GCC; this keeps the slow 3-core runner inside the
# job time limit.
log "Build (gmake -j$(sysctl -n hw.ncpu)), no bootstrap"
gmake -j"$(sysctl -n hw.ncpu)"

# ---------------------------------------------------------------------------
log "Install into prefix"
gmake install

# ---------------------------------------------------------------------------
log "Verify toolchain"
BINDIR="$PREFIX/bin"
"$BINDIR/gcc-16" --version | tee "$WORKSPACE/gcc-version.txt"

# Smoke test: C and C++
cat > "$WORKSPACE/hello.c" <<'EOF'
#include <stdio.h>
int main(void){ printf("cc ok\n"); return 0; }
EOF
cat > "$WORKSPACE/hello.cc" <<'EOF'
#include <iostream>
int main(){ std::cout << "cxx ok\n"; return 0; }
EOF
"$BINDIR/gcc-16"   "$WORKSPACE/hello.c"  -o "$WORKSPACE/hello-c"
"$BINDIR/g++-16"   "$WORKSPACE/hello.cc" -o "$WORKSPACE/hello-cxx"
"$WORKSPACE/hello-c"
"$WORKSPACE/hello-cxx"

echo "--- dynamic libraries linked by gcc-16 ---"
otool -L "$BINDIR/gcc-16" | tee "$WORKSPACE/gcc-16.otool.txt"

echo "--- NLS message catalogs installed ---"
find "$PREFIX" -name '*.mo' | tee "$WORKSPACE/nls-mo.txt"

echo "--- front ends installed ---"
ls "$BINDIR" | grep -E '-(16)$' | sort | tee "$WORKSPACE/frontends.txt"

# ---------------------------------------------------------------------------
log "Package bundle"
# Drop the build tree before archiving; the prefix is the self-contained product.
rm -rf "$BUILD"
tar -C "$PREFIX" -czf "$BUNDLE" .
ls -lh "$BUNDLE"
echo "BUNDLE=$BUNDLE"
