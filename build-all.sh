#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-all.sh -- reproducible, zero-manual-step build of the modified
# PostgreSQL 18.3 kernel (postgresql_modified_for_babelfish) plus the four
# Babelfish extensions (common, money, tds, tsql).
#
# MySQL compatibility is built independently from the sibling
# mysql_extensions repository.  Its three PGXS modules were removed from the
# kernel tree in pluginization Phase 2, so do not add a kernel-contrib build
# loop here.
#
# What this removes (see FUSION_PLAN.md P1-2/P1-3/P1-5/P1-8/P1-10):
#   - manual CPPFLAGS="-DHAVE_BIO_METH_NEW -DHAVE_OPENSSL_INIT_SSL"  (now in
#     tds_secure.h, derived from OPENSSL_VERSION_NUMBER)
#   - manual CPPFLAGS="-I/usr/include/libxml2"  (now in PGXS CPPFLAGS via
#     meson; requires the kernel built with libxml, which this script sets)
#   - manual make CXX=g++  (now in PGXS Makefile.global via meson)
#   - manual symlinks babelfishpg_common-6.so / babelfishpg_tsql-6.so  (module
#     files are unversioned everywhere now, matching pl_handler.c's loader)
#   - manual make cmake=cmake  (defaulted in babelfishpg_tsql/Makefile)
#
# One-time environment prerequisites (already present on the dev machine):
#   meson, ninja, make, cc/c++, pkg-config, libxml2 + OpenSSL headers, java
#   (JRE), cmake, and the ANTLR4 4.13.2 C++ runtime with headers under
#   /usr/local/include/antlr4-runtime.  See FUSION_PLAN.md section 5.6.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$SCRIPT_DIR/../postgresql_modified_for_babelfish}"
PREFIX="${PREFIX:-$KERNEL_DIR/inst}"

if [ ! -d "$KERNEL_DIR" ]; then
    echo "kernel tree not found: $KERNEL_DIR" >&2
    echo "point KERNEL_DIR at postgresql_modified_for_babelfish and retry" >&2
    exit 1
fi

for tool in meson ninja make cc c++ pkg-config cmake java flex perl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -f /usr/local/include/antlr4-runtime/antlr4-runtime.h ] || {
    echo "ANTLR4 4.13.2 runtime headers not found under /usr/local/include/antlr4-runtime" >&2
    echo "install the matching runtime first (FUSION_PLAN.md section 5.6)" >&2
    exit 1
}

# --- kernel ----------------------------------------------------------------
cd "$KERNEL_DIR"
if [ ! -d build ]; then
    # uuid=e2fs: babelfishpg_tsql hard-requires uuid-ossp (P1-11).
    # libxml=enabled: PGXS CPPFLAGS then carry the libxml2 include path (P1-3).
    meson setup build --prefix="$PREFIX" -Duuid=e2fs -Dlibxml=enabled
fi
ninja -C build
ninja -C build install

PGCONFIG="$PREFIX/bin/pg_config"
PKGLIBDIR="$("$PGCONFIG" --pkglibdir)"

# --- extensions -------------------------------------------------------------
cd "$SCRIPT_DIR"
for ext in babelfishpg_common babelfishpg_money babelfishpg_tds babelfishpg_tsql; do
    echo "===== building $ext ====="
    (cd "contrib/$ext" && \
        make USE_PGXS=1 PG_CONFIG="$PGCONFIG" PG_SRC="$KERNEL_DIR" \
             -j"$(nproc)" all install)
done

echo
echo "all Babelfish extensions built and installed:"
ls "$PKGLIBDIR" | grep -E 'babelfish'
echo
echo "build the independent MySQL modules next:"
echo "  $SCRIPT_DIR/../mysql_extensions/build-all.sh"
echo
echo "restart any running cluster to pick up the new binaries:"
echo "  $PREFIX/bin/pg_ctl -D <data-dir> restart"
