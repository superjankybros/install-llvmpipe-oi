#!/bin/bash
# build-mesa-llvmpipe-all.sh
# One script: builds LLVM (only if not already built), then Mesa with llvmpipe.
# Target: OpenIndiana Hipster, x86_64. Untested on real illumos hardware.
#
# Usage:   bash build-mesa-llvmpipe-all.sh
# Re-run is safe: finished LLVM is skipped, downloads are reused.
set -euo pipefail

LLVM_VER="${LLVM_VER:-17.0.6}"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-mesa}"
MESA_VER="${MESA_VER:-24.0.9}"
MESA_PREFIX="${MESA_PREFIX:-/opt/mesa-llvmpipe}"
WORK="${WORK:-$HOME/mesa-llvmpipe-work}"
JOBS="${JOBS:-$(psrinfo | wc -l | tr -d ' ')}"

step() { printf '\n==> %s\n' "$*"; }
untar() { gtar xf "$1" 2>/dev/null || tar xf "$1"; }

mkdir -p "$WORK"
cd "$WORK"

########################################################################
# Stage 0: packages
########################################################################
step "Installing build tools (package names may differ on your snapshot)"
# Installed one at a time: a single bad package name makes pkg abort the
# whole multi-package install, which would leave everything uninstalled.
FAILED=""
for p in \
    developer/gcc-13 \
    developer/build/cmake \
    developer/build/meson \
    developer/build/ninja \
    developer/build/gnu-make \
    developer/parser/bison \
    developer/lexer/flex \
    developer/pkg-config \
    developer/lang/python-39 \
    library/python/mako-39 \
    library/python/pyyaml-39 \
    library/python/packaging-39 \
    archiver/gnu-tar \
    x11/library/libx11 x11/library/libxext x11/library/libxcb \
    x11/library/libxshmfence x11/library/libxxf86vm x11/library/libxfixes \
    x11/header/x11-protocols \
    library/zlib compress/zstd
do
    if pkg list "$p" >/dev/null 2>&1; then
        echo "already installed: $p"
    elif pfexec pkg install --accept "$p"; then
        echo "installed: $p"
    else
        echo "FAILED: $p  (wrong name? try: pkg search -r ${p##*/})"
        FAILED="$FAILED $p"
    fi
done
[ -z "$FAILED" ] || echo "NOTE: these packages did not install:$FAILED"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is not installed. Find it with: pkg search -r $1"; exit 1; }; }

########################################################################
# Stage 1: LLVM (skipped if already built)
########################################################################
LLVM_CONFIG="$LLVM_PREFIX/bin/llvm-config"

if [ -x "$LLVM_CONFIG" ]; then
    step "LLVM already built at $LLVM_PREFIX, skipping (delete that dir to rebuild)"
else
    need cmake
    need ninja
    step "Building LLVM $LLVM_VER (this takes an hour or more on 4 cores)"
    [ -f "llvm-project-$LLVM_VER.src.tar.xz" ] || \
        curl -fLO "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VER/llvm-project-$LLVM_VER.src.tar.xz"
    [ -d "llvm-project-$LLVM_VER.src" ] || untar "llvm-project-$LLVM_VER.src.tar.xz"

    # Do NOT delete llvm-build here: ninja resumes from where it stopped.
    cmake -S "llvm-project-$LLVM_VER.src/llvm" -B llvm-build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$LLVM_PREFIX" \
        -DLLVM_TARGETS_TO_BUILD=X86 \
        -DLLVM_BUILD_LLVM_DYLIB=ON \
        -DLLVM_LINK_LLVM_DYLIB=ON \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_PARALLEL_LINK_JOBS=1 \
        2>&1 | tee llvm-cmake.log

    ninja -C llvm-build -j "$JOBS" 2>&1 | tee llvm-build.log
    pfexec ninja -C llvm-build install

    [ -x "$LLVM_CONFIG" ] || { echo "LLVM install finished but $LLVM_CONFIG is missing. Check llvm-build.log"; exit 1; }
fi

LLVM_LIBDIR="$("$LLVM_CONFIG" --libdir)"
echo "Using $LLVM_CONFIG (LLVM $("$LLVM_CONFIG" --version)), libdir $LLVM_LIBDIR"

########################################################################
# Stage 2: Mesa with llvmpipe
########################################################################
need meson
need ninja
step "Fetching Mesa $MESA_VER"
[ -f "mesa-$MESA_VER.tar.xz" ] || \
    curl -fLO "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz"
[ -d "mesa-$MESA_VER" ] || untar "mesa-$MESA_VER.tar.xz"
cd "mesa-$MESA_VER"

step "Configuring Mesa"
export CC=gcc CXX=g++
export CFLAGS="-m64 -O2 -D__EXTENSIONS__"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-m64 -Wl,-R,$LLVM_LIBDIR"
export PKG_CONFIG_PATH="/usr/lib/amd64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"

printf "[binaries]\nllvm-config = '%s'\n" "$LLVM_CONFIG" > native.ini

rm -rf build
meson setup build \
    --prefix="$MESA_PREFIX" \
    --buildtype=release \
    --native-file=native.ini \
    -Dllvm=enabled \
    -Dshared-llvm=enabled \
    -Dgallium-drivers=llvmpipe,softpipe \
    -Dvulkan-drivers= \
    -Dplatforms=x11 \
    -Dglx=xlib \
    -Degl=disabled \
    -Dgbm=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dgallium-va=disabled \
    -Dgallium-vdpau=disabled \
    -Dshader-cache=disabled \
    -Dlmsensors=disabled \
    -Dvalgrind=disabled \
    2>&1 | tee configure.log

step "Building Mesa with $JOBS jobs"
ninja -C build -j "$JOBS" 2>&1 | tee build.log

step "Installing Mesa to $MESA_PREFIX"
pfexec ninja -C build install

cat <<EOF

==> Done. Test with:
  export LD_LIBRARY_PATH_64=$MESA_PREFIX/lib/amd64:$MESA_PREFIX/lib
  export GALLIUM_DRIVER=llvmpipe
  export LIBGL_ALWAYS_SOFTWARE=1
  glxinfo | grep -E 'renderer|version'    # expect "llvmpipe (LLVM ...)"
  glxgears

If libGL is not under lib/amd64 or lib, find it with:
  find $MESA_PREFIX -name 'libGL*'
EOF
