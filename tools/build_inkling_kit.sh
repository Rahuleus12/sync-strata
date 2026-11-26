#!/usr/bin/env bash
# Build the Inkling 2 Mini engine kit (Linux, NVIDIA CUDA) inside this checkout.
#
#   tools/build_inkling_kit.sh [--portable] [--archs "75;80;86;89;120"] [--jobs N] [--clean]
#
# What it makes (nothing outside this checkout is written):
#   build/engine-inkling2/        the CMake build tree
#   build/kit-linux-inkling2/     the kit: bin/strata, bin/strata-ink2, serve/ (the server that knows Inkling's chat
#                                 format), BUILD.json, start-inkling.sh
#
# The engine source: $ENGINE_SRC, else engine/ (the submodule) when it has the Inkling path, else ../sync-strata-engine.
# llama.cpp (the pinned ggml the engine builds against) is fetched by CMake on the first build, or taken from
# $LLAMACPP_SRC.  Needs CUDA 13 (nvcc), CMake 3.24+, Ninja and a host compiler nvcc accepts (gcc-14 is used if found).
#
# Default: CUDA architectures of this PC's GPU and the CPU code tuned for this CPU (fastest here).  --portable: the GPUs
# Sync-Strata supports with CUDA 13 (RTX 20 to 50) and an AVX2 baseline, for a kit other PCs can use.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTABLE=0
ARCHS=""
JOBS="$(nproc)"
CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --portable) PORTABLE=1 ;;
    --archs) ARCHS="$2"; shift ;;
    --jobs|-j) JOBS="$2"; shift ;;
    --clean) CLEAN=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

has_inkling() { [ -f "$1/CMakeLists.txt" ] && [ -f "$1/src/inkling2/ink2_dspark.inc" ]; }
if [ -n "${ENGINE_SRC:-}" ]; then
  SRC="$(cd "$ENGINE_SRC" && pwd)"
elif has_inkling "$HERE/engine"; then
  SRC="$HERE/engine"
elif has_inkling "$HERE/../sync-strata-engine"; then
  SRC="$(cd "$HERE/../sync-strata-engine" && pwd)"
else
  echo "No engine source with the Inkling 2 path: set ENGINE_SRC, or check out engine/ (git submodule update --init)." >&2
  exit 1
fi
has_inkling "$SRC" || { echo "$SRC has no src/inkling2 (DSpark): not an engine with the Inkling 2 path" >&2; exit 1; }

NVCC="${NVCC:-$(command -v nvcc || echo /opt/cuda/bin/nvcc)}"
[ -x "$NVCC" ] || { echo "nvcc not found (set NVCC or put CUDA 13 on PATH)" >&2; exit 1; }
CUDA_MAJOR="$("$NVCC" --version | sed -n 's/.*release \([0-9]*\)\..*/\1/p')"
[ "${CUDA_MAJOR:-0}" -ge 13 ] || echo "warning: nvcc is CUDA ${CUDA_MAJOR:-?}; the kit is meant for CUDA 13" >&2

if [ -z "$ARCHS" ]; then
  if [ "$PORTABLE" = 1 ]; then
    ARCHS="75;80;86;89;120"
  else
    ARCHS="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d '.' | sort -u | paste -sd';' || true)"
    [ -n "$ARCHS" ] || ARCHS="75;80;86;89;120"
  fi
fi

HOSTCXX=()
for v in 14 13; do
  if command -v "g++-$v" >/dev/null && command -v "gcc-$v" >/dev/null; then
    HOSTCXX=(-DCMAKE_C_COMPILER="$(command -v gcc-$v)" -DCMAKE_CXX_COMPILER="$(command -v g++-$v)"
             -DCMAKE_CUDA_HOST_COMPILER="$(command -v g++-$v)")
    break
  fi
done

BDIR="$HERE/build/engine-inkling2"
KIT="$HERE/build/kit-linux-inkling2"
[ "$CLEAN" = 1 ] && rm -rf "$BDIR"
mkdir -p "$BDIR"

LLAMA=()
if [ -n "${LLAMACPP_SRC:-}" ]; then
  LLAMA=(-DFETCHCONTENT_SOURCE_DIR_STRATA_LLAMACPP="$LLAMACPP_SRC")
fi

echo "engine source: $SRC"
echo "CUDA archs:    $ARCHS  (portable: $PORTABLE)"
cmake -S "$SRC" -B "$BDIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DSTRATA_ENABLE_CUDA=ON -DSTRATA_NATIVE_EXPERTS=ON -DSTRATA_BUILD_TESTS=OFF \
  -DSTRATA_Q6K_EXPERTS=ON -DSTRATA_MMQ_KQUANTS=ON \
  -DSTRATA_PORTABLE="$([ "$PORTABLE" = 1 ] && echo ON || echo OFF)" \
  -DCMAKE_CUDA_ARCHITECTURES="$ARCHS" -DCMAKE_CUDA_COMPILER="$NVCC" \
  "${HOSTCXX[@]}" "${LLAMA[@]}" >"$BDIR/configure.log" 2>&1 \
  || { tail -30 "$BDIR/configure.log" >&2; exit 1; }
cmake --build "$BDIR" --target strata strata-ink2 -j "$JOBS"

# ---- the kit
rm -rf "$KIT.tmp"
mkdir -p "$KIT.tmp/bin" "$KIT.tmp/serve"
cp "$BDIR/strata" "$BDIR/strata-ink2" "$KIT.tmp/bin/"
strip --strip-unneeded "$KIT.tmp/bin/strata" "$KIT.tmp/bin/strata-ink2" 2>/dev/null || true
# the server in the same layout as the app's engine/serve: serve/ (the package), tools/ (the tokenizer and the GGUF
# reader it imports), strata_cli/ and strata_control/; no tests, fixtures or caches
copy_tree() {   # copy_tree <src dir> <dst dir>
  (cd "$1" && find . -type f \
      ! -path '*/__pycache__/*' ! -name '*.pyc' ! -name 'test_*' ! -path './fixtures/*' -print0 \
    | while IFS= read -r -d '' f; do mkdir -p "$2/$(dirname "$f")"; cp "$f" "$2/$f"; done)
}
copy_tree "$SRC/serve" "$KIT.tmp/serve/serve"
for d in strata_cli strata_control; do [ -d "$SRC/$d" ] && copy_tree "$SRC/$d" "$KIT.tmp/serve/$d"; done
mkdir -p "$KIT.tmp/serve/tools"
find "$SRC/tools" -maxdepth 1 -type f -name '*.py' ! -name 'test_*' -exec cp {} "$KIT.tmp/serve/tools/" \;
cp "$SRC/LICENSE" "$KIT.tmp/serve/LICENSE-Strata.txt"
[ -f "$SRC/requirements.txt" ] && cp "$SRC/requirements.txt" "$KIT.tmp/serve/"
cp "$HERE/tools/inkling/start-inkling.sh" "$KIT.tmp/"
chmod +x "$KIT.tmp/start-inkling.sh" "$KIT.tmp/bin/"*

REV="$(git -C "$SRC" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git -C "$SRC" status --porcelain 2>/dev/null | head -1 | grep -q . && echo true || echo false)"
echo "$REV$([ "$DIRTY" = true ] && echo +local)" > "$KIT.tmp/serve/STRATA_SERVE_VERSION.txt"
python3 - "$KIT.tmp/BUILD.json" "$REV" "$DIRTY" "$ARCHS" "$PORTABLE" "$("$NVCC" --version | tail -1)" <<'EOF'
import json, sys, time
out, rev, dirty, archs, portable, nvcc = sys.argv[1:]
json.dump({"kind": "inkling2", "backend": "cuda", "engine_commit": rev, "engine_local_changes": dirty == "true",
           "cuda_archs": archs.split(";"), "portable": portable == "1", "nvcc": nvcc,
           "built_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
           "families": ["inkling2_loop"], "features": ["dspark", "cpu-experts", "paged-kv-262144", "prompt-checkpoint"]},
          open(out, "w"), indent=1)
EOF
rm -rf "$KIT"
mv "$KIT.tmp" "$KIT"
echo
echo "kit: $KIT"
"$KIT/bin/strata" --version 2>/dev/null | head -1 || true
du -sh "$KIT" | cut -f1 | sed 's/^/size: /'
