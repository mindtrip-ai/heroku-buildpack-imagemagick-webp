#!/bin/bash
# Verify a built ImageMagick tarball before tagging it.
# Run from the root of the heroku-buildpack-imagemagick-webp fork:
#   ./verify-tarball.sh            # defaults to build/imagemagick-heroku-24.tar.gz
#   ./verify-tarball.sh build/imagemagick-heroku-26.tar.gz
set -uo pipefail

TARBALL=${1:-build/imagemagick-heroku-24.tar.gz}
STACK_IMAGE=heroku/heroku:24
case "$TARBALL" in *heroku-26*) STACK_IMAGE=heroku/heroku:26 ;; esac

fail() { echo "FAIL: $*"; exit 1; }

[ -f "$TARBALL" ] || fail "$TARBALL does not exist"
echo "== tarball: $TARBALL ($(du -h "$TARBALL" | cut -f1)), runtime image: $STACK_IMAGE"

# Guard against a git-lfs pointer masquerading as the binary.
[ "$(stat -f%z "$TARBALL" 2>/dev/null || stat -c%s "$TARBALL")" -gt 10000000 ] \
  || fail "tarball is under 10MB - likely a git-lfs pointer, not the real archive"

# --- Gate 1: architecture, checked on the host ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
tar xzf "$TARBALL" -C "$TMP" || fail "tarball will not extract"
[ -x "$TMP/bin/magick" ] || fail "no bin/magick in the tarball"
ARCH=$(file "$TMP/bin/magick")
echo "== $ARCH"
case "$ARCH" in
  *x86-64*) echo "PASS gate 1: x86-64 binary" ;;
  *aarch64*|*arm64*) fail "gate 1: ARM binary - build.sh is missing the --platform linux/amd64 pin" ;;
  *) fail "gate 1: unrecognised architecture" ;;
esac

BUILD_ABS=$(cd "$(dirname "$TARBALL")" && pwd)

# --- Gates 2-5: behaviour, checked inside the real runtime image ---
# --user root because heroku/heroku:24 defaults to uid 1000 and has no /app;
# the slug layout is what we want to reproduce, so we create it.
docker run --rm -i --user root --platform linux/amd64 \
  -v "$BUILD_ABS:/b:ro" "$STACK_IMAGE" bash -s -- "$(basename "$TARBALL")" <<'INNER'
set -uo pipefail
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p /app/vendor/imagemagick || fail "setup: cannot create /app/vendor/imagemagick"
tar xzf "/b/$1" -C /app/vendor/imagemagick || fail "setup: tarball will not extract in the runtime image"
export MAGICK_HOME=/app/vendor/imagemagick
export PATH=$MAGICK_HOME/bin:$PATH
export LD_LIBRARY_PATH=$MAGICK_HOME/lib:${LD_LIBRARY_PATH:-}

# Gate 2: the binary is present, runs, and every shared library resolves.
[ -x "$MAGICK_HOME/bin/magick" ] || fail "gate 2: bin/magick missing after extraction"
LDD_OUT=$(ldd "$MAGICK_HOME/bin/magick" 2>&1) || fail "gate 2: ldd failed: $LDD_OUT"
if echo "$LDD_OUT" | grep -q "not found"; then
  echo "$LDD_OUT" | grep "not found"
  fail "gate 2: unresolved shared libraries"
fi
command -v magick >/dev/null || fail "gate 2: magick is not on PATH after extraction"
magick -version >/dev/null 2>&1 || fail "gate 2: magick will not execute in the runtime image"
echo "PASS gate 2: magick executes and all shared libraries resolve"
magick -version | head -2

# Gate 3: the HEIC and WebP delegates are actually compiled in, read+write.
FORMATS=$(magick -list format) || fail "gate 3: magick -list format failed"
for fmt in HEIC WEBP JPEG PNG; do
  # IM7 prints "Format Mode Description" - one name column, mode is field 2.
  line=$(echo "$FORMATS" | grep -iE "^ *${fmt}\*? +[r-][w-][+-]" | head -1)
  [ -n "$line" ] || fail "gate 3: $fmt not in the format list"
  mode=$(echo "$line" | awk '{print $2}')
  case "$mode" in *rw*) ;; *) fail "gate 3: $fmt is present but mode is $mode" ;; esac
  echo "   $line"
done
echo "PASS gate 3: HEIC, WEBP, JPEG, PNG all read+write"

# Gate 4: the IM7 subcommand dispatch that lib/image_magick.rb depends on.
magick -size 64x64 xc:red /tmp/t.png || fail "gate 4: cannot create a test image"
magick /tmp/t.png /tmp/t.webp || fail "gate 4: PNG -> WebP conversion failed"
magick /tmp/t.png /tmp/t.heic || fail "gate 4: PNG -> HEIC conversion failed"
echo "   round-trip: $(magick identify -format '%m %wx%h' /tmp/t.webp), $(magick identify -format '%m %wx%h' /tmp/t.heic)"
magick identify -format '%m %w %h\n' /tmp/t.png >/dev/null || fail "gate 4: 'magick identify' subcommand is gone"
magick montage /tmp/t.png /tmp/t.png -tile 2x -geometry +0+0 /tmp/m.png || fail "gate 4: 'magick montage' subcommand is gone"
echo "PASS gate 4: magick identify and magick montage both dispatch"

# Gate 5: the resource limits our wrapper always passes still parse.
magick -limit memory 256MB -limit map 512MB -limit disk 8GB -limit time 120 \
  /tmp/t.png -auto-orient -resize 32x32 -strip -quality 80 /tmp/s.jpg \
  || fail "gate 5: -limit flags rejected"
magick -define jpeg:size=64x64 /tmp/t.png -resize 32x32 /tmp/d.jpg \
  || fail "gate 5: -define jpeg:size rejected"
echo "PASS gate 5: resource limits and jpeg:size hint accepted"

echo
echo "ALL GATES PASSED"
INNER
