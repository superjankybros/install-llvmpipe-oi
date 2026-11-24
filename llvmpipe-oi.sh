#!/bin/sh
# build-mesa-llvmpipe.sh - Mesa with llvmpipe (software GL) on OpenIndiana Hipster
set -eu

MESA_VER="${MESA_VER:-24.0.9}"
PREFIX="${PREFIX:-/opt/mesa-llvmpipe}"
SRC="${SRC:-$HOME/mesa-build}"
JOBS="${JOBS:-$(psrinfo | wc -l | tr -d ' ')}"

step() { printf '\n==> %s\n' "$*"; }

step "Installing build dependencies (check names with: pkg search -r <name>)"
# Package names vary between Hipster snapshots; adjust if any are not found.
pkg install --accept \
    developer/gcc-13 \
    developer/build/meson \
    developer/build/ninja \
    developer/build/gnu-make \
    developer/parser/bison \
    developer/lexer/flex \
    developer/pkg-config \
    developer/llvm-17 \
    developer/lang/python-39 \
    library/python/mako-39 \
    library/python/pyyaml-39 \
    library/python/packaging-39 \
    x11/library/libx11 x11/library/libxext x11/library/libxcb \
    x11/library/libxshmfence x11/library/libxxf86vm x11/library/libxfixes \
    x11/header/x11-protocols \
    library/zlib compress/zstd \
    || echo "WARNING: some packages failed to install; continuing, meson will tell us what is missing"

step "Locating llvm-config"
LLVM_CONFIG="$(command -v llvm-config 2>/dev/null || ls /usr/llvm/*/bin/llvm-config 2>/dev/null | tail -1 || true)"
[ -x "${LLVM_CONFIG:-}" ] || { echo "llvm-config not found; run: pkg search llvm"; exit 1; }
echo "Using $LLVM_CONFIG (LLVM $($LLVM_CONFIG --version))"

step "Fetching Mesa $MESA_VER"
mkdir -p "$SRC" && cd "$SRC"
[ -f "mesa-$MESA_VER.tar.xz" ] || \
    curl -LO "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz"
[ -d "mesa-$MESA_VER" ] || gtar xf "mesa-$MESA_VER.tar.xz" 2>/dev/null || tar xf "mesa-$MESA_VER.tar.xz"
cd "mesa-$MESA_VER"

step "Configuring"
export CC="gcc" CXX="g++"
export CFLAGS="-m64 -O2 -march=skylake -D__EXTENSIONS__"
export CXXFLAGS="$CFLAGS"
export PKG_CONFIG_PATH="/usr/lib/amd64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"

rm -rf build
meson setup build \
    --prefix="$PREFIX" \
    --buildtype=release \
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
    --native-file=<(printf "[binaries]\nllvm-config = '%s'\n" "$LLVM_CONFIG") 2>&1 \
    | tee configure.log

step "Building with $JOBS jobs"
ninja -C build -j "$JOBS" 2>&1 | tee build.log

step "Installing to $PREFIX"
ninja -C build install

cat <<EOF

Done. Test with:
  export LD_LIBRARY_PATH_64=$PREFIX/lib/amd64:$PREFIX/lib
  export GALLIUM_DRIVER=llvmpipe
  export LIBGL_ALWAYS_SOFTWARE=1
  glxinfo | grep -E 'renderer|version'    # expect "llvmpipe (LLVM ...)"
  glxgears

Optional: LP_NUM_THREADS=4 to set llvmpipe's thread count.
EOF
