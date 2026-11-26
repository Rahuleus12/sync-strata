# Inkling 2 Mini

English | [日本語](INKLING2.ja.md)

Sync-Strata can run [Inkling 2 Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini) by Thinking Machines
(Apache 2.0) next to its Qwen models. It is a 26.4 billion parameter mixture of experts with 3.4 billion active per
token; its middle 12 layers run three times for every token.

> **Experimental.** Linux, NVIDIA cards (CUDA 13) only. Text only (no pictures yet), one request at a time. Its engine
> is a separate kit that you build from source today (below); release packages do not include it yet.

What you get:

- **DSpark drafting.** A small draft model guesses up to 3 tokens ahead and Inkling checks them in one step. Writing
  is about 30 to 47% faster (measured below), and the answer is the model's own: a guess is kept only where the model agrees.
- **Up to 256K context.** The cache grows with the conversation, so a short chat leaves the GPU memory to the model.
- **More model than GPU memory.** The experts that do not fit on the card stay in RAM, and the CPU computes them
  while the card computes the rest.
- **Chats continue without rereading.** The next turn of a chat reuses the earlier prompt.
- The OpenAI and Anthropic APIs, reasoning (as reasoning / thinking blocks) and tool calls, on the same port as the
  Qwen models.

## Models

| In the model list | File | Size |
| --- | --- | ---: |
| **Inkling 2 Mini Uncensored** | AtomicChat's `Inkling-2-Mini-Uncensored-AD-Q4_K.gguf` ([repository](https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF)) | 16.5 GB |
| **Inkling 2 Mini** | Unsloth's `Mainline_Support/Inkling-2-Mini-UD-Q4_K_XL.gguf_file` ([repository](https://huggingface.co/unsloth/Inkling-2-Mini-GGUF)) | 17.6 GB |
| DSpark (shared by both) | Unsloth's `Mainline_Support/dspark-Inkling-2-Mini-Q8_0.gguf_file` | 0.5 GB |

The uncensored file is the same model with a rank-1 edit baked in (same tokenizer and chat template). Neither model
file has the drafter inside it; the app downloads it with either model. Every file is pinned to a repository revision
and checked by SHA-256 after the download.

## What your PC needs

| | |
| --- | --- |
| GPU | NVIDIA, CUDA 13 driver (R580 or newer). Measured on an RTX 5060 Ti 16 GB. Cards with less memory keep more experts in RAM (slower; not measured) |
| RAM | 24 GB or more (the experts that are not on the card are kept in RAM). Measured with 31 GB |
| CPU | AVX2. The CPU computes the experts in RAM: memory bandwidth matters (dual-channel DDR4 gave about 40 GB/s) |
| Disk | 17 to 18 GB for a model, 0.5 GB for the drafter, 0.2 GB for the engine kit |

## Build the engine kit

From this checkout (Linux). You need CUDA 13 (`nvcc`), CMake 3.24 or newer, Ninja and a C++ compiler nvcc accepts
(gcc 14 is used when it is installed). The engine source is the sibling `sync-strata-engine` checkout, or the `engine/`
submodule once it carries the Inkling path; `ENGINE_SRC=<dir>` picks another.

```sh
tools/build_inkling_kit.sh              # for this PC's GPU and CPU (fastest here)
tools/build_inkling_kit.sh --portable   # RTX 20 to 50 and an AVX2 baseline, for other PCs
```

It writes only inside this checkout: the build tree `build/engine-inkling2/` and the kit `build/kit-linux-inkling2/`
(`bin/strata`, `bin/strata-ink2`, the server `serve/` that knows Inkling's chat format, `BUILD.json`,
`start-inkling.sh`). The first build fetches the pinned llama.cpp (ggml) and takes 20 to 40 minutes; set
`LLAMACPP_SRC=<dir>` to use a copy you already have.

## Use it

**All at once:** `./inkling.sh` (in this checkout) builds the kit if needed, installs it into the app, links the model
(the first `.gguf` in `../Inkling-2-Mini-Uncensored-GGUF/`, or `INKLING_MODEL=<file>`), downloads the DSpark drafter if
it is missing, stops the Qwen engine, starts Inkling on the app's API port, then starts dsh and opens the Sync-Strata
chat window on it (dsh's prompt names the model Inkling). Each step is skipped when already done. `--no-open` leaves
the window closed (dsh and the phone page still run), `--api-only` starts the engine alone, `--stop` stops Inkling
(`sync down` stops everything), `--rebuild` builds the kit again; other options go to `start-inkling.sh`. While
Inkling runs, the app's icon and `sync up --gui` open the chat on it. The steps one by one:

### With the installed app (now)

```sh
tools/install_inkling_kit.sh --link-model <your Inkling-2-Mini-Uncensored-AD-Q4_K.gguf> --link-dspark <your dspark file>
sync down --engine                                   # the Qwen engine and Inkling share the API port
~/.local/share/SyncStrata/app/engine-inkling2/start-inkling.sh
```

`install_inkling_kit.sh` copies the kit to `<app>/engine-inkling2` (the previous one is kept as `engine-inkling2.prev`)
and, if you pass them, links the files you already have into the app's models folder under the names the model list
uses. It changes nothing else of the app.

`start-inkling.sh` starts Inkling on the app's API port (the `api_port` setting), so the chat page, the phone and any
program using the API talk to it. It finds the model and the drafter in the models folder; `--model`, `--dspark`
(`off` to write without it), `--context`, `--port` override that. It reads the tokenizer from the GGUF once.
`start-inkling.sh --stop` stops it.

The app's own model list and its start button come with the next app built from this branch (below). The installed
0.1.4 app does not know the Inkling models yet.

### From the app's model list (the next app build)

The model list shows **Inkling 2 Mini Uncensored** and **Inkling 2 Mini**. Download one: the drafter comes with it,
and none of the Qwen shared parts are needed. Start it like any model. The tail skip choice is hidden for these
models (it is a Qwen setting). From the terminal:

```sh
sync up --model inkling-2-mini-uncensored            # or inkling-2-mini; --api-only for the API alone
sync down --engine
```

With `--model auto` (the default), the app starts an Inkling model only when no Qwen model is on the PC.

The context is 256K unless the `context` setting or `sync up --context` asks for less. The engine lowers it if the card
cannot hold it, and says so when it starts.

## Speed

> Measured on an RTX 5060 Ti 16 GB (PCIe 4.0 x8), Ryzen 5 5600X (6 cores), 31 GB DDR4 (dual channel), Linux,
> CUDA 13.5, on 2026-11-24, with the context set to 256K and the drafter loaded.

Writing 300 tokens of a code answer (greedy):

| Model | Without DSpark | With DSpark | Guesses kept |
| --- | ---: | ---: | ---: |
| Inkling 2 Mini Uncensored | 44.2 tokens/s | 64.8 tokens/s | 71% |
| Inkling 2 Mini (UD-Q4_K_XL) | 40.5 tokens/s | 53.0 tokens/s | 62% |

| Test (Uncensored) | Speed |
| --- | ---: |
| Through this kit's server, a short code question | 54.7 tokens/s writing (53% of guesses kept) |
| Reading a 2,048-token prompt | 199 tokens/s (UD-Q4_K_XL: 219) |
| Reading a 15,000-token prompt, then writing | 173 tokens/s, then 50.8 tokens/s |
| The next turn of that chat (15,122 tokens reused) | 17.9 s to the end of the answer, 102 s without the reuse |
| Reading a 250,000-token prompt | 47 tokens/s on average (88 minutes), then 13.3 tokens/s writing without DSpark |

## Limits

- Linux and NVIDIA (CUDA 13) only. The Windows, CUDA 12 and Radeon engines do not have the Inkling path.
- No pictures yet: AtomicChat's `mmproj` (the vision tower) is not used.
- One request at a time.
- A very long prompt is slow to read (the 250K row above). Give a long document once; the next turns reuse it.
- At temperature 1.0 fewer guesses are kept than with greedy decoding (the drafter guesses greedily).
- The Qwen settings (RAM budget, tail skip, KV format, the refusal-reduction vector, expert learning) do not apply.
- AtomicChat's smaller files (AD-IQ3_S, AD-IQ2_M) and Unsloth's other sizes are not set up.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| `Inkling 2 Mini のエンジン（engine-inkling2）が入っていません` (`sync up`) | Build and install the kit (above) |
| `port … is in use` (`start-inkling.sh`) | The Qwen engine is running: `sync down --engine`, or `--port <other>` |
| `no 'regex' module` | Run it with the app's Python (`PYTHON=<app>/python/bin/python3`), or `pip install regex` |
| No DSpark warning | Put the drafter in the models folder (`--link-dspark`) or pass `--dspark <file>` |
| The engine stopped | `~/.config/SyncStrata/inkling/engine.log` (`start-inkling.sh`) or `<SYNC_HOME>/run/strata-auto.log` (`sync up`) |

## For developers

| Part | Where |
| --- | --- |
| Engine (Inkling path, DSpark, CPU experts, paged cache) | `sync-strata-engine`: `src/inkling2/`, `docs/INKLING2_MINI.md`, `docs/work/inkling2/MATH.md` |
| Kit build and install | `tools/build_inkling_kit.sh`, `tools/install_inkling_kit.sh`, `tools/inkling/start-inkling.sh` |
| Model list | `app/chat/models/models.dist.json`: the models with `"engine": "inkling2"` (no `experts_gib`, so never a Qwen pack), the shared part `inkling2-dspark` (`only_for` the Inkling models) |
| Relay | `app/chat/server.mjs`: a model's shared parts are its `needs` (`sharedFor`); models with `engine` are never the recommendation |
| Launcher | `app/launcher/sync_launch.py`: `inkling_model`, `inkling_config`, `inkling_up`; `sync_home.LAYOUT["inkling_kit"]` |
| Page | `app/chat/public/strata.js`: no tail skip and no RAM-fit line for models with `engine` |
| Packaging | `packaging/sources.example.json`: the optional component `engine-inkling2` (Linux) |
| Tests | `cd app/launcher && python -m unittest test_inkling -v` |
