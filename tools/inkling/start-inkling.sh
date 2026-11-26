#!/usr/bin/env bash
# Start Inkling 2 Mini (with DSpark, up to 256K context) on Sync-Strata's API port.
#
#   start-inkling.sh [--model <file.gguf>] [--dspark <drafter.gguf>|off] [--context N] [--port N] [--host ADDR]
#                    [--name NAME] [--foreground] [--stop]
#
# This script sits in the Inkling kit (build/kit-linux-inkling2, or <app>/engine-inkling2 once installed).  It writes a
# server config and starts the kit's own server (serve/serve/server.py) with the kit's engine (bin/strata).  The app's
# chat page and anything that uses the OpenAI or Anthropic API on that port then talk to Inkling.
#
# Defaults:
#   --model    the first of: $INKLING_MODEL; <models dir>/inkling-2-mini-uncensored/Inkling-2-Mini-Uncensored-AD-Q4_K.gguf;
#              <models dir>/inkling-2-mini/Inkling-2-Mini-UD-Q4_K_XL.gguf
#   --dspark   $INKLING_DSPARK; else dspark-Inkling-2-Mini-Q8_0.gguf (or Unsloth's ...gguf_file name) next to the model
#              or in <models dir>/inkling-2-mini-dspark/; else off with a warning
#   --context  262144 (the engine lowers it if the card cannot hold it, and says so)
#   --port     Sync-Strata's api_port setting when it is a number, else 8080
# The models dir is Sync-Strata's models_dir setting, else ~/.local/share/SyncStrata/models.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/SyncStrata"
STATE="${SYNC_HOME:-$CONF}/inkling"
SETTINGS="$CONF/settings.json"

MODEL="${INKLING_MODEL:-}"
DSPARK="${INKLING_DSPARK:-}"
CTX=262144
PORT=""
HOST="127.0.0.1"
NAME=""
FG=0
STOP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift ;;
    --dspark) DSPARK="$2"; shift ;;
    --context) CTX="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --host) HOST="$2"; shift ;;
    --name) NAME="$2"; shift ;;
    --foreground) FG=1 ;;
    --stop) STOP=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

setting() {   # setting <name>: Sync-Strata's setting when set and not "auto"
  [ -f "$SETTINGS" ] || return 0
  "$PY" -I -c 'import json,sys
v=json.load(open(sys.argv[1],encoding="utf-8")).get(sys.argv[2])
print("" if v in (None,"auto") else v)' "$SETTINGS" "$1" 2>/dev/null || true
}

mkdir -p "$STATE"
PIDF="$STATE/server.pid"
if [ "$STOP" = 1 ]; then
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    P="$(cat "$PIDF")"; kill "$P"
    for _ in $(seq 1 120); do kill -0 "$P" 2>/dev/null || break; sleep 0.5; done   # the server drains and frees the GPU
    kill -0 "$P" 2>/dev/null && { echo "pid $P did not stop in 60 s; ending it"; kill -9 "$P"; }
    echo "stopped (pid $P)"; rm -f "$PIDF"
  else
    echo "not running"
  fi
  exit 0
fi

# Python: the app's own (when this kit is <app>/engine-inkling2), else $PYTHON, else python3.  The server needs `regex`.
PY="${PYTHON:-}"
if [ -z "$PY" ] && [ -x "$KIT/../python/bin/python3" ]; then PY="$KIT/../python/bin/python3"; fi
PY="${PY:-python3}"
"$PY" -c "import regex" 2>/dev/null || { echo "$PY has no 'regex' module (pip install regex, or set PYTHON)" >&2; exit 1; }

MODELS="$(setting models_dir)"
MODELS="${MODELS:-$HOME/.local/share/SyncStrata/models}"
if [ -z "$MODEL" ]; then
  for f in "$MODELS/inkling-2-mini-uncensored/Inkling-2-Mini-Uncensored-AD-Q4_K.gguf" \
           "$MODELS/inkling-2-mini/Inkling-2-Mini-UD-Q4_K_XL.gguf"; do
    [ -f "$f" ] && { MODEL="$f"; break; }
  done
fi
[ -n "$MODEL" ] && [ -f "$MODEL" ] || { echo "no Inkling 2 Mini GGUF found: pass --model <file.gguf>" >&2; exit 1; }
MODEL="$(cd "$(dirname "$MODEL")" && pwd)/$(basename "$MODEL")"

if [ -z "$DSPARK" ]; then
  for f in "$(dirname "$MODEL")/dspark-Inkling-2-Mini-Q8_0.gguf" \
           "$MODELS/inkling-2-mini-dspark/dspark-Inkling-2-Mini-Q8_0.gguf" \
           "$MODELS/inkling-2-mini-dspark/Mainline_Support/dspark-Inkling-2-Mini-Q8_0.gguf_file"; do
    [ -f "$f" ] && { DSPARK="$f"; break; }
  done
  [ -n "$DSPARK" ] || { echo "warning: no DSpark drafter found; writing without it (about a third slower)" >&2; DSPARK=off; }
fi

if [ -z "$PORT" ]; then
  PORT="$(setting api_port)"
  [[ "$PORT" =~ ^[0-9]+$ ]] || PORT=8080
fi

# the tokenizer and chat template, read from the GGUF once per file
TOK="$STATE/tokenizer-$(basename "$MODEL" .gguf)-$(stat -c %s "$MODEL")"
if [ ! -f "$TOK/tokenizer/vocab.json" ]; then
  echo "reading the tokenizer from $(basename "$MODEL") (once)..."
  "$PY" -s "$KIT/serve/tools/strata_tokenizer.py" --gguf "$MODEL" --out "$TOK.tmp" >/dev/null
  rm -rf "$TOK"; mv "$TOK.tmp" "$TOK"
fi

LIBS=("$KIT/bin")
[ -d "$KIT/../engine-cuda13/bin" ] && LIBS+=("$(cd "$KIT/../engine-cuda13/bin" && pwd)")
for d in "${CUDA_HOME:-}/lib64" /opt/cuda/lib64 /usr/local/cuda/lib64; do [ -d "$d" ] && LIBS+=("$d"); done

[ -n "$NAME" ] || NAME="inkling-2-mini$(basename "$MODEL" | grep -qi uncensored && echo -uncensored)"
CFG="$STATE/inkling.json"
LOG="$STATE/engine.log"
"$PY" -I - "$CFG" "$KIT" "$MODEL" "$DSPARK" "$CTX" "$TOK/tokenizer" "$NAME" "$LOG" "$PORT" "${LIBS[@]}" <<'EOF'
import json, sys
cfg, kit, model, dspark, ctx, tok, name, log, port, *libs = sys.argv[1:]
args = ["--native", model, "--max-context", ctx, "--prefill", "auto"]
if dspark != "off":
    args += ["--dspark", dspark, "--dspark-n", "3"]
json.dump({"exe": kit + "/bin/strata", "args": args, "cwd": kit + "/serve", "tokenizer": tok, "model_name": name,
           "arch": "inkling2_loop", "log": log, "port": int(port), "lib_dirs": libs,
           "note": "written by start-inkling.sh (Inkling 2 Mini kit)"}, open(cfg, "w"), indent=1)
EOF

if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "already running (pid $(cat "$PIDF")); stop it first: $0 --stop" >&2; exit 1
fi
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  echo "port $PORT is in use (Sync-Strata's engine? stop it: sync down --engine, or use --port)" >&2; exit 1
fi

CMD=("$PY" -s -X utf8 "$KIT/serve/serve/server.py" --engine strata --config "$CFG" --host "$HOST" --port "$PORT")
echo "model:   $MODEL"
echo "dspark:  $DSPARK"
echo "context: $CTX   port: $PORT   log: $LOG"
if [ "$FG" = 1 ]; then exec "${CMD[@]}"; fi
# its own session: a closed terminal or a signal to this shell's process group does not stop it (--stop does)
setsid nohup "${CMD[@]}" </dev/null >"$STATE/server.log" 2>&1 &
echo $! > "$PIDF"
echo -n "starting (pid $!)"
for _ in $(seq 1 300); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then echo; echo "ready: http://127.0.0.1:$PORT/v1"; exit 0; fi
  kill -0 "$(cat "$PIDF")" 2>/dev/null || { echo; echo "the server stopped; see $STATE/server.log and $LOG" >&2; exit 1; }
  echo -n .; sleep 2
done
echo; echo "not ready after 10 minutes; see $STATE/server.log" >&2; exit 1
