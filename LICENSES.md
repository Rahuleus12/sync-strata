# Licenses / ライセンス

Sync-Strata's own code is under the [MIT License](LICENSE). The release zip and the models also contain the parts below, each under its own license. The release zip carries every notice in its `licenses/` folder (`licenses/README.txt` is the index).
Sync-Strata のコードは [MIT](LICENSE) です。配布の zip とモデルには、下の部品がそれぞれのライセンスで入っています。

## Sync-Strata (this repository)

| Part | License | Notice to keep |
|---|---|---|
| Engine, server, app (fork of [Strata](https://github.com/Niko1221/Strata); the source with upstream's history: [sync-strata-engine](https://github.com/hiruhiru2005/sync-strata-engine)) | MIT | `Copyright (c) 2026 Niko1221 and the Strata contributors` and `Copyright (c) 2026 hiruhiru2005` (`LICENSE`) |
| Gyro trellis types and kernels (agentionai, via Strata): the types, the Hadamard rotation, the CPU and GPU kernels and the pack step from agentionai/Strata `rc2`; `third_party/ggml/ggml-common-tq.h` and the MMQ instances from agentionai/llama.cpp (as stated in upstream Strata's `docs/GYRO.md`). The Gyro format's specification and reference decoder/encoder that agentionai publishes under Apache-2.0 are not included. | MIT | Kept in Strata's history and `LICENSE`; `third_party/ggml/LICENSE` |
| [llama.cpp / ggml](https://github.com/ggml-org/llama.cpp) (`third_party/ggml`) | MIT | `third_party/ggml/LICENSE` |
| [Project Maya](https://github.com/mw00/project-maya) (`src/dsv41`, via Strata) | MIT | `third_party/project-maya/LICENSE`, `NOTICE.md` |
| Image reader `strata-vision` (upstream Strata's released build for RTX 20-50 on Windows; a CPU-only build made from the same source for the GTX 10, Radeon and Linux releases) | MIT (Strata), with llama.cpp's `mtmd` library (MIT) | `sync-strata/LICENSE-Strata.txt`, `engine/LICENSE-ggml-llama.cpp.txt` |
| [Outfit](https://github.com/Outfitio/Outfit-Fonts) font (engine web page) | SIL OFL 1.1 | `serve/web/fonts/OFL.txt` |

## Bundled programs / 同梱するプログラム

| Part | License | Redistribution | Notice to keep |
|---|---|---|---|
| NVIDIA cuBLAS 13.0 (`cublas64_13.dll`, `cublasLt64_13.dll`; Linux: `libcublas.so.13`, `libcublasLt.so.13`, `libcudart.so.13`) | NVIDIA CUDA Toolkit EULA | Allowed: listed as redistributable in Attachment A, shipped with an application that adds material functionality and only used by it | `licenses/nvidia/NOTICE-NVIDIA-cuBLAS.txt` ([CUDA EULA](https://docs.nvidia.com/cuda/eula/)); each engine folder also carries `NOTICE-NVIDIA.txt` and `LICENSE-NVIDIA-CUDA.txt` |
| NVIDIA CUDA 12.9 runtime and cuBLAS (CUDA 12 engine for the GTX 10 series: `cudart64_12.dll`, `cublas64_12.dll`, `cublasLt64_12.dll`; Linux: `libcudart.so.12`, `libcublas.so.12`, `libcublasLt.so.12`) | NVIDIA CUDA Toolkit EULA | Allowed (same terms as above) | `NOTICE-NVIDIA.txt` and `LICENSE-NVIDIA-CUDA12.txt` (Linux: `LICENSE-NVIDIA-CUDA.txt`) in the CUDA 12 engine folder |
| Node.js 24.19.0 (`dsh-node.exe`, a renamed `node.exe`) | MIT, plus the licenses of the parts it bundles (OpenSSL, ICU, libuv, V8 and others) | Allowed | `licenses/node/LICENSE-Node.js-24.19.0.txt` |
| Python 3.12.10 (embeddable) | PSF-2.0, plus the bundled parts (OpenSSL, libffi, SQLite and others) | Allowed | `python/LICENSE.txt` (already there) |
| Python packages (28: numpy, huggingface_hub, hf_xet, requests, pillow, psutil, pyyaml, jinja2, tqdm, certifi and others) | MIT, BSD, Apache-2.0, PSF, MPL-2.0 (certifi, part of tqdm), MIT-CMU (pillow) | Allowed (MPL-2.0: unmodified files, source is upstream) | The license files in each `*.dist-info` (already there) |
| [dsh](https://www.npmjs.com/package/@deepseek-ai/dsh) 0.2.0-rc.2 and its `node_modules` (537 packages) | Mostly MIT (448), Apache-2.0 (57), BSD (16), ISC (9); MPL-2.0 (LibreOffice kit, 2); Apache-2.0 AND LGPL-3.0-or-later (sharp's libvips, 1) | Allowed with conditions: MPL-2.0 and LGPL-3.0 need their license text and where to get the source; LGPL also lets users replace the library (it is a separate DLL) | `licenses/npm/THIRD-PARTY-NOTICES-npm.txt` (every package; for the 19 without a license file the notice is made from package.json); `licenses/copyleft/` for LGPL-3.0 and MPL-2.0 and where to get their source |
| [Tauri](https://tauri.app/) 2 and Rust crates (446 in `Cargo.lock`) | MIT OR Apache-2.0 for most; MPL-2.0 (cssparser, selectors, dtoa-short, option-ext); Unicode-3.0 (ICU4X data) | Allowed | `licenses/rust/` (the list and the full texts) |
| Linux: Python and its packages, Node.js (Linux builds) | Same licenses as the Windows builds (PSF-2.0, the package licenses, MIT for Node) | Allowed | Same files under `licenses/python-linux/` and `licenses/node/` [unchecked: made when the Linux bundle exists] |
| Linux: the parts inside the AppImage (AppImage runtime, and any system libraries it carries, for example WebKitGTK and GTK, which are LGPL-2.1) | Per part [unchecked: depends on what the AppImage actually carries] | Expected to be allowed; LGPL parts need their text and where to get the source | `licenses/linux-appimage/` [unchecked] |
| HIP engine, Windows: AMD ROCm 10.2.0a20260930 from AMD's TheRock wheels, unmodified (`amdhip64_7.dll`, `amd_comgr.dll`, `hipblas.dll`, `libhipblaslt.dll`, `rocblas.dll`, `rocsolver.dll`, `origami.dll`, `libtensilelite-host.dll`, `rocm_kpack.dll`) | MIT (rocBLAS, hipBLAS, hipBLAS-common, hipBLASLt, rocm-core, the HIP runtime, rocm_kpack); BSD-2-Clause (rocSOLVER); Apache-2.0 with LLVM exceptions (amd_comgr) | Allowed | `bin/rocm/licenses/` in each HIP engine folder (`NOTICE.txt` and the license files) |
| HIP engine: Microsoft Visual C++ runtime DLLs (`msvcp140.dll`, `msvcp140_atomic_wait.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`) | Microsoft Visual Studio license (Distributable Code) | Allowed as redistributable files | `bin/rocm/licenses/NOTICE.txt` |
| HIP engine, Linux: the same ROCm libraries plus `libLLVM`, `libclang-cpp` and `libomp` (LLVM), `libgcc_s` and `libstdc++` (GCC runtime from conda-forge), and TheRock's `rocm_sysdeps` libraries (libdrm, libnuma, libelf, liblzma, zlib, zstd, bzip2), `librocprofiler-register`, `libroctx64` | MIT for the ROCm libraries; Apache-2.0 with LLVM exceptions for LLVM; GPL-3.0 with the GCC Runtime Library Exception for the GCC runtime; each `rocm_sysdeps` library keeps its own license (some are LGPL) | Expected to be allowed. For the GCC runtime the exception text is included; for the LLVM libraries, the `rocm_sysdeps` libraries, `libomp` and `librocprofiler-register` the license texts and, for the LGPL ones, where to get the source are **not yet in the release** [unchecked: to be added] | `bin/rocm/licenses/` (ROCm and the GCC runtime exceptions only, so far) |
| [dsh-rustxng](https://github.com/kgmkm/dsh-rustxng) (e0efc31, the dsh plug-in for web search, in `dsh/plugins/`) | MIT | Allowed | `dsh/plugins/dsh-rustxng/LICENSE` |
| [RustXNG](https://github.com/sahenjp/RustXNG) v0.27.0 (the web search engine) | AGPL-3.0-or-later | **Not bundled**: downloaded from upstream's GitHub release on the first web search (checked against the published SHA-256 and a pinned one), and run as a separate program | — |
| Microsoft Edge WebView2 Runtime | Microsoft software license | Not bundled: the app uses the runtime already on Windows | — |
| [Zen Kaku Gothic New](https://github.com/googlefonts/zen-kakugothic) Bold (chat page) | SIL OFL 1.1 | Allowed with the software; not sold by itself | `OFL-ZenKakuGothicNew.txt` (already there) |
| Sync-Strata SC: a subset of [Noto Sans SC](https://github.com/google/fonts/tree/main/ofl/notosanssc), renamed (app window, Chinese) | SIL OFL 1.1 | Allowed with the software; not sold by itself | `fonts/OFL-NotoSansSC.txt`, and the app's `THIRD-PARTY-NOTICES.txt` |

## Models / モデル（Hugging Face）

| Part | From | License |
|---|---|---|
| Sync-XS, Sync-S, Sync-M packs | Re-quantized from [Qwen/Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) | Qwen Community License 1.0 |
| Shared part `native-gguf` | Cut from [agentionai/Qwen3.8-Flash-Next-Gyro-GGUF](https://huggingface.co/agentionai/Qwen3.8-Flash-Next-Gyro-GGUF) (Gyro-S) | Qwen Community License 1.0 (the license of that repository) |
| Shared part `mtp-rt` | Converted from Qwen3.8-Flash-Next (BF16); `draft_vocab.bin` from Strata | Qwen Community License 1.0; `draft_vocab.bin` MIT (Strata) |
| Shared part `tokenizer` | Qwen3.8-Flash-Next | Qwen Community License 1.0 |
| Vision projector `mmproj` (optional; not redistributed, downloaded from the original repository) | [ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF) | The card says it inherits the base model's license (Qwen Community License 1.0); the repository metadata says Apache-2.0 |
| Expert profile (`expert-profile-upstream.bin`, in the engine) | Strata's `data/expert-profile.bin` (the same bytes) | MIT (Strata) |
| Control vector for "Fewer refusals" (`Qwen3.8-Flash-Next-experimental-speed-projection.gguf`, in the engine's `data`; used only when the setting is on) | Strata's `terminal/data/experimental-speed-projection/` (the same bytes), made from Qwen3.8-Flash-Next activations | Qwen Community License 1.0 (as stated by Strata) |

The Qwen Community License 1.0 allows use, copying, modification and redistribution, including commercial use, if the copyright and permission notice is kept with every copy. Two conditions: a commercial product with more than 100 million monthly active users or US$20 million monthly revenue must show the model name prominently, and a Model-as-a-Service or AI work assistant (coding or office) business needs a separate license from Qwen before any commercial use.
