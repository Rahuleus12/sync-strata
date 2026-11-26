#!/usr/bin/env bash
# Inkling 2 Mini in Sync-Strata, in one command (Linux, NVIDIA):
#
#   ./inkling.sh                 build the kit if needed, install it into the app, link the model, fetch the DSpark
#                                drafter if it is missing, stop the Qwen engine, start Inkling on the app's API port,
#                                then start dsh and open the Sync-Strata chat window on it
#   ./inkling.sh --no-open       the same without opening the window (dsh and the phone page still run)
#   ./inkling.sh --api-only      only the engine (no dsh)
#   ./inkling.sh --stop          stop Inkling (the app's own start brings Qwen back)
#   ./inkling.sh --rebuild       build the kit again first (after engine changes)
#   ./inkling.sh [start-inkling.sh options]    e.g. --context 131072, --dspark off, --port 18555, --foreground
#
# Every step is skipped when it is already done.  Overrides: INKLING_MODEL=<file.gguf> (default: the first .gguf in
# ../Inkling-2-Mini-Uncensored-GGUF/), INKLING_DSPARK=<file>, SYNC_APP=<app dir> (default ~/.local/share/SyncStrata/app).
# Docs: docs/INKLING2.md
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${SYNC_APP:-$HOME/.local/share/SyncStrata/app}"
KIT="$HERE/build/kit-linux-inkling2"
DST="$APP/engine-inkling2"
REBUILD=0
NO_GUI=0
NO_OPEN=0
PASS=()
for a in "$@"; do
  case "$a" in
    --rebuild) REBUILD=1 ;;
    --api-only) NO_GUI=1 ;;
    --no-open) NO_OPEN=1 ;;
    --stop) "$DST/start-inkling.sh" --stop; exit 0 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) PASS+=("$a") ;;
  esac
done
step() { printf '\n== %s\n' "$*"; }

[ -d "$APP/launcher" ] || { echo "Sync-Strata is not installed at $APP (set SYNC_APP)" >&2; exit 1; }
PY="$APP/python/bin/python3"

# 1. the kit
if [ "$REBUILD" = 1 ] || [ ! -x "$KIT/bin/strata" ]; then
  step "building the engine kit (20-40 minutes the first time)"
  "$HERE/tools/build_inkling_kit.sh"
else
  step "engine kit: built ($KIT)"
fi

# the start script is not compiled: the kit takes the one in tools/ whenever it changed
cmp -s "$HERE/tools/inkling/start-inkling.sh" "$KIT/start-inkling.sh" || install -m 755 "$HERE/tools/inkling/start-inkling.sh" "$KIT/"

# 2. the model and the drafter
MODEL="${INKLING_MODEL:-}"
if [ -z "$MODEL" ]; then
  MODEL="$(ls "$HERE"/../Inkling-2-Mini-Uncensored-GGUF/*.gguf 2>/dev/null | grep -iv mmproj | head -1 || true)"
fi
[ -n "$MODEL" ] && [ -f "$MODEL" ] || { echo "no model file: set INKLING_MODEL=<Inkling-2-Mini-...gguf>" >&2; exit 1; }

DSPARK="${INKLING_DSPARK:-}"
if [ -z "$DSPARK" ]; then
  for f in "$HERE"/../ink2-work/dl/dspark/dspark-Inkling-2-Mini-Q8_0*.gguf "$(dirname "$MODEL")"/dspark-Inkling-2-Mini-Q8_0*.gguf \
           "$HERE/build/dspark/dspark-Inkling-2-Mini-Q8_0.gguf"; do
    [ -f "$f" ] && { DSPARK="$f"; break; }
  done
fi
if [ -z "$DSPARK" ]; then
  step "downloading the DSpark drafter (0.5 GB, Unsloth, pinned revision)"
  mkdir -p "$HERE/build/dspark"
  DSPARK="$HERE/build/dspark/dspark-Inkling-2-Mini-Q8_0.gguf"
  curl -fL --retry 3 -o "$DSPARK.part" \
    "https://huggingface.co/unsloth/Inkling-2-Mini-GGUF/resolve/7005eb3bf10e03aca23449baac79fdd0d105dd31/Mainline_Support/dspark-Inkling-2-Mini-Q8_0.gguf_file"
  echo "3da00cf7c31bbe5662b3c0d373ecf782d74d32ef43990acc158ce60c2add72e0  $DSPARK.part" | sha256sum -c --quiet \
    || { rm -f "$DSPARK.part"; echo "the drafter's SHA-256 does not match" >&2; exit 1; }
  mv "$DSPARK.part" "$DSPARK"
fi

# 3. install the kit when the app's copy is not this build (and link the files into the app's models folder)
if [ ! -f "$DST/BUILD.json" ] || ! cmp -s "$KIT/BUILD.json" "$DST/BUILD.json" || ! cmp -s "$KIT/start-inkling.sh" "$DST/start-inkling.sh"; then
  step "installing the kit into $DST"
  "$HERE/tools/install_inkling_kit.sh" --app "$APP" --link-model "$MODEL" --link-dspark "$DSPARK"
else
  step "kit installed: $DST"
fi

# 4. Inkling on the app's API port (unless it already runs)
STATE="${SYNC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/SyncStrata}/inkling"
if [ -f "$STATE/server.pid" ] && kill -0 "$(cat "$STATE/server.pid")" 2>/dev/null; then
  step "Inkling is already running (pid $(cat "$STATE/server.pid"))"
else
  # 5. stop the Qwen engine (it holds the API port and the GPU memory)
  step "stopping the Qwen engine if it runs"
  "$PY" -X utf8 "$APP/launcher/sync.py" down --engine 2>&1 | tail -1 || true
  # 6. start (the model and drafter found above; options given to this script win)
  step "starting Inkling 2 Mini"
  ARGS=(--model "$MODEL")
  [[ " ${PASS[*]-} " == *" --dspark "* ]] || ARGS+=(--dspark "$DSPARK")
  "$DST/start-inkling.sh" "${ARGS[@]}" "${PASS[@]}"
fi
[[ " ${PASS[*]-} " == *" --foreground "* ]] && exit 0
[ "$NO_GUI" = 1 ] && exit 0

# 7. dsh and the chat window, on the engine that runs (the app's launcher sees Strata up and starts only dsh and
#    the relay).  The model's name in dsh's prompt: the launcher writes it from choice.json, which knows only the Qwen
#    packs, so it is written here and choice.json names the Inkling model (the launcher then leaves the name as it is).
step "starting dsh and the chat window"
SH="${SYNC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/SyncStrata}"
case "$(basename "$MODEL")" in
  *Uncensored*) MID=inkling-2-mini-uncensored; MNAME="Inkling 2 Mini Uncensored" ;;
  *) MID=inkling-2-mini; MNAME="Inkling 2 Mini" ;;
esac
mkdir -p "$SH/run" "$SH/models-state"
printf '%s\n' "$MNAME" > "$SH/run/head-model-name.txt"
printf '{"model": "%s", "r": null, "at": %s, "by": "inkling.sh"}' "$MID" "$(date +%s000)" > "$SH/models-state/choice.json"
"$PY" -X utf8 "$APP/launcher/sync.py" up --gui $([ "$NO_OPEN" = 1 ] || echo --open) 2>&1 | grep -vE "^\s*(OpenAI|Anthropic|鍵|多くの|curl|日本語|速さと)" || true
