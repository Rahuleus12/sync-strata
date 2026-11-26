#!/usr/bin/env bash
# Build the Linux CUDA 13 engine for a release (the Qwen packs and Inkling 2 Mini in one engine), in Docker, the way the
# release's engine was built: glibc 2.28 baseline, GPUs sm_75 / sm_86 / sm_120 (+ PTX), AVX2 base with the wider CPU
# kernels picked at run time (STRATA_PORTABLE), static libstdc++ / libgcc, RUNPATH $ORIGIN, the build paths mapped away.
#
#   tools/release/build_engine.sh [--src <engine source>] [--archs "75;86;120"] [--jobs N]
#
# Output: build/engine-release/{strata, strata-ink2, libstrata_kq.so} (and the CMake tree).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$HERE/build/engine-src"
ARCHS="75;86;120"
JOBS="$(nproc)"
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="$(cd "$2" && pwd)"; shift ;;
    --archs) ARCHS="$2"; shift ;;
    --jobs) JOBS="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -f "$SRC/src/inkling2/ink2_dspark.inc" ] || { echo "$SRC: not an engine source with the Inkling path" >&2; exit 1; }
IMG=sync-strata-engine-build:cuda13.0.2-el8
docker build -q -t "$IMG" -f "$HERE/tools/release/engine.Dockerfile" "$HERE/tools/release" >/dev/null
OUT="$HERE/build/engine-release"
mkdir -p "$OUT"
LLAMA=()
[ -n "${LLAMACPP_SRC:-}" ] && LLAMA=(-v "$LLAMACPP_SRC:/llama:ro" -e LLAMA=/llama)
# the source read-only at /src, the build at /out; the CUDA archs and flags as the release's BUILD.json says
docker run --rm --user "$(id -u):$(id -g)" -v "$SRC:/src:ro" -v "$OUT:/out" "${LLAMA[@]}" -e HOME=/tmp \
  -e ARCHS="$ARCHS" -e JOBS="$JOBS" "$IMG" bash -ec '
    MAP="-ffile-prefix-map=/src=. -ffile-prefix-map=/out=. -ffile-prefix-map=/llama=llama"
    FC=(); [ -n "${LLAMA:-}" ] && FC=(-DFETCHCONTENT_SOURCE_DIR_STRATA_LLAMACPP=$LLAMA)
    ARCH_LIST="$(echo "$ARCHS" | sed "s/;\([0-9]*\)$/;\1-real;\1-virtual/; s/\([0-9][0-9]*\)\(;\)/\1-real\2/g")"
    cmake -S /src -B /out -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DSTRATA_ENABLE_CUDA=ON -DSTRATA_PORTABLE=ON -DSTRATA_NATIVE_EXPERTS=ON -DSTRATA_Q6K_EXPERTS=ON \
      -DSTRATA_MMQ_KQUANTS=ON -DSTRATA_EXPERIMENTAL_SM60=OFF -DSTRATA_BUILD_TESTS=OFF \
      -DCMAKE_CUDA_ARCHITECTURES="$ARCH_LIST" -DCMAKE_CUDA_HOST_COMPILER=g++ \
      -DCMAKE_C_FLAGS="$MAP" -DCMAKE_CXX_FLAGS="$MAP" -DCMAKE_CUDA_FLAGS="-Xcompiler=${MAP// /,}" \
      -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ -static-libgcc -Wl,-rpath,\$ORIGIN" \
      -DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc -Wl,-rpath,\$ORIGIN" \
      -DCMAKE_SKIP_BUILD_RPATH=OFF -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH="\$ORIGIN" \
      "${FC[@]}" > /out/configure.log 2>&1 || { tail -40 /out/configure.log; exit 1; }
    cmake --build /out --target strata strata-ink2 strata_kq -j "$JOBS"
    strip --strip-unneeded /out/strata /out/strata-ink2 /out/libstrata_kq.so
  '
echo "built: $OUT/strata $OUT/strata-ink2 $OUT/libstrata_kq.so"
