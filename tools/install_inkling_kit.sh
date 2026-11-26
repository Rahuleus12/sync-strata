#!/usr/bin/env bash
# Put the Inkling 2 Mini kit (made by tools/build_inkling_kit.sh) into an installed Sync-Strata (Linux).
#
#   tools/install_inkling_kit.sh [--app <app dir>] [--kit <kit dir>] [--link-model <file.gguf>] [--link-dspark <file>]
#
#   --app          the installed app (default: ~/.local/share/SyncStrata/app)
#   --kit          default: build/kit-linux-inkling2 in this checkout
#   --link-model   a GGUF you already have: linked (not copied) into the app's models folder where the model list looks
#                  for it (inkling-2-mini-uncensored/ or inkling-2-mini/, by its file name)
#   --link-dspark  the DSpark drafter you already have: linked into inkling-2-mini-dspark/
#
# The kit goes to <app>/engine-inkling2 (the one there before is kept as engine-inkling2.prev).  Nothing else of the app
# is changed: its Qwen engine, serve and launcher stay as they are.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/.local/share/SyncStrata/app"
KIT="$HERE/build/kit-linux-inkling2"
MODEL=""
DSPARK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift ;;
    --kit) KIT="$2"; shift ;;
    --link-model) MODEL="$2"; shift ;;
    --link-dspark) DSPARK="$2"; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -x "$KIT/bin/strata" ] && [ -f "$KIT/serve/serve/server.py" ] || { echo "no kit at $KIT (run tools/build_inkling_kit.sh)" >&2; exit 1; }
[ -d "$APP/launcher" ] || { echo "no Sync-Strata app at $APP (--app <dir>)" >&2; exit 1; }

DST="$APP/engine-inkling2"
rm -rf "$DST.new"
cp -a "$KIT" "$DST.new"
if [ -d "$DST" ]; then rm -rf "$DST.prev"; mv "$DST" "$DST.prev"; fi
mv "$DST.new" "$DST"
echo "kit installed: $DST ($(cat "$DST/serve/STRATA_SERVE_VERSION.txt" 2>/dev/null))"

# the app's models folder: the models_dir setting, else <SyncStrata>/models
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/SyncStrata/settings.json"
MD=""
if [ -f "$CONF" ]; then
  MD="$(python3 -I -c 'import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8")).get("models_dir")
print("" if v in (None,"auto") else v)' "$CONF" 2>/dev/null || true)"
fi
MD="${MD:-$(dirname "$APP")/models}"

link() {   # link <file> <dir> <name>
  local src; src="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  [ -f "$src" ] || { echo "not a file: $1" >&2; exit 1; }
  mkdir -p "$2"
  if [ -e "$2/$3" ] && [ ! -L "$2/$3" ]; then echo "kept: $2/$3 (a file is already there)"; return; fi
  ln -sfn "$src" "$2/$3"
  echo "linked: $2/$3 -> $src"
}
if [ -n "$MODEL" ]; then
  case "$(basename "$MODEL")" in
    Inkling-2-Mini-Uncensored-AD-Q4_K.gguf) link "$MODEL" "$MD/inkling-2-mini-uncensored" Inkling-2-Mini-Uncensored-AD-Q4_K.gguf ;;
    Inkling-2-Mini-UD-Q4_K_XL.gguf*) link "$MODEL" "$MD/inkling-2-mini/Mainline_Support" Inkling-2-Mini-UD-Q4_K_XL.gguf_file ;;
    *) echo "unknown file name: $(basename "$MODEL") (expected AtomicChat's Inkling-2-Mini-Uncensored-AD-Q4_K.gguf or Unsloth's Inkling-2-Mini-UD-Q4_K_XL.gguf)" >&2; exit 1 ;;
  esac
fi
if [ -n "$DSPARK" ]; then
  link "$DSPARK" "$MD/inkling-2-mini-dspark/Mainline_Support" dspark-Inkling-2-Mini-Q8_0.gguf_file
  link "$DSPARK" "$MD/inkling-2-mini-dspark" dspark-Inkling-2-Mini-Q8_0.gguf
fi
echo
echo "start it:  $DST/start-inkling.sh        (stop: $DST/start-inkling.sh --stop)"
