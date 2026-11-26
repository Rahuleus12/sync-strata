# Inkling 2 Mini

[English](INKLING2.md) | 日本語

Sync-Strata は，Qwen のモデルのほかに Thinking Machines の [Inkling 2 Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini)（Apache 2.0）も動かせます．
264 億パラメーターの MoE（1 トークンで動くのは 34 億）で，中ほどの 12 層を 1 トークンごとに 3 回通します．

> **試験的．** Linux・NVIDIA の GPU（CUDA 13）だけです．文字だけ（画像はまだ）で，頼みは 1 つずつです．
> エンジンは別のキットで，今はソースから作ります（下）．配布物にはまだ入っていません．

できること:

- **DSpark の下書き．** 小さな下書きのモデルが 3 トークン先まで当て，Inkling が 1 回でまとめて確かめます．書く速さは 3〜4 割ほど上がり（下の測定），答えはモデル自身の物です（モデルが同じ答えを出す所だけ下書きを使う）．
- **文脈 256K まで．** 記憶（キャッシュ）は会話に合わせて育つので，短い会話のうちは GPU のメモリをモデルに回します．
- **GPU のメモリより大きいモデル．** カードに入らない専門家は RAM に置き，カードが残りを計算するのと同時に CPU が計算します．
- **会話の続きは読み直さない．** 次の発言では前の頼みの分をそのまま使います．
- OpenAI・Anthropic の API，推論（reasoning・thinking のブロック），ツールの呼び出しを，Qwen のモデルと同じ番号で．

## モデル

| 一覧の名前 | ファイル | 大きさ |
| --- | --- | ---: |
| **Inkling 2 Mini Uncensored** | AtomicChat の `Inkling-2-Mini-Uncensored-AD-Q4_K.gguf`（[置き場](https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF)） | 16.5 GB |
| **Inkling 2 Mini** | Unsloth の `Mainline_Support/Inkling-2-Mini-UD-Q4_K_XL.gguf_file`（[置き場](https://huggingface.co/unsloth/Inkling-2-Mini-GGUF)） | 17.6 GB |
| DSpark（2 つで共通） | Unsloth の `Mainline_Support/dspark-Inkling-2-Mini-Q8_0.gguf_file` | 0.5 GB |

検閲を外した版は，同じモデルに rank-1 の手直しを焼き込んだ物です（トークナイザーと会話の形は同じ）．どちらのモデルのファイルにも下書きのモデルは入っていません．アプリはどちらのモデルのときも一緒に落とします．どのファイルも置き場の版を決めて落とし，SHA-256 で確かめます．

## 要る物

| | |
| --- | --- |
| GPU | NVIDIA，CUDA 13 のドライバー（R580 以上）．測ったのは RTX 5060 Ti 16 GB．メモリの少ないカードは RAM に置く専門家が増える（遅くなる．未測定） |
| RAM | 24 GB 以上（カードに無い専門家は RAM に置く）．測ったのは 31 GB |
| CPU | AVX2．RAM の専門家は CPU が計算するので，メモリの速さが効く（DDR4 2 チャンネルで約 40 GB/s） |
| ディスク | モデル 17〜18 GB，下書き 0.5 GB，エンジンのキット 0.2 GB |

## エンジンのキットを作る

この写しの中で（Linux）．CUDA 13（`nvcc`），CMake 3.24 以上，Ninja，nvcc が受け付ける C++ のコンパイラー（gcc 14 があれば使う）が要ります．エンジンのソースは隣の `sync-strata-engine` の写し，または Inkling の道が入った後の `engine/`（サブモジュール）です．`ENGINE_SRC=<フォルダー>` で別の物を選べます．

```sh
tools/build_inkling_kit.sh              # この PC の GPU と CPU 向け（ここでいちばん速い）
tools/build_inkling_kit.sh --portable   # RTX 20〜50 と AVX2 の基準（ほかの PC 向け）
```

書くのはこの写しの中だけです: 組み立ての置き場 `build/engine-inkling2/` とキット `build/kit-linux-inkling2/`（`bin/strata`，`bin/strata-ink2`，Inkling の会話の形を知るサーバー `serve/`，`BUILD.json`，`start-inkling.sh`）．初回は決めた版の llama.cpp（ggml）を取ってきて 20〜40 分かかります．手元の写しは `LLAMACPP_SRC=<フォルダー>` で使えます．

## 使う

**まとめて 1 回で:** この写しの `./inkling.sh` が，要ればキットを作り，アプリに入れ，モデルをリンクし（`../Inkling-2-Mini-Uncensored-GGUF/` の最初の `.gguf`，か `INKLING_MODEL=<ファイル>`），下書きのモデルが無ければ落とし，Qwen のエンジンを止めて，アプリの API の番号で Inkling を起こし，その上で dsh を起こして Sync-Strata の会話の窓を開きます（dsh の指示文のモデルの名前は Inkling）．済んでいる手順は飛ばします．`--no-open` は窓を開かない（dsh とスマホの画面は動く），`--api-only` はエンジンだけ，`--stop` は Inkling を止める（全部は `sync down`），`--rebuild` は作り直し，ほかの指定は `start-inkling.sh` に渡します．Inkling が動いている間は，アプリのアイコンや `sync up --gui` もその上で会話の画面を開きます．1 つずつの手順は下のとおりです．

### 入れてあるアプリで（今すぐ）

```sh
tools/install_inkling_kit.sh --link-model <手元の Inkling-2-Mini-Uncensored-AD-Q4_K.gguf> --link-dspark <手元の dspark のファイル>
sync down --engine                                   # Qwen のエンジンと Inkling は API の番号を分け合う
~/.local/share/SyncStrata/app/engine-inkling2/start-inkling.sh
```

`install_inkling_kit.sh` はキットを `<app>/engine-inkling2` に写し（前の物は `engine-inkling2.prev` に残す），渡したファイルをモデルの一覧が探す名前でアプリのモデルの置き場にリンクします．アプリのほかの所は変えません．

`start-inkling.sh` は Inkling をアプリの API の番号（設定 `api_port`）で起こします．会話の画面・スマホ・API を使うプログラムがそのまま Inkling と話します．モデルと下書きはモデルの置き場から探し，`--model`・`--dspark`（`off` で下書きなし）・`--context`・`--port` で替えられます．トークナイザーは初回に GGUF から読み出します．止めるのは `start-inkling.sh --stop`．

アプリのモデルの一覧と起動のボタンは，この枝から作る次のアプリに入ります（下）．今入っている 0.1.4 のアプリはまだ Inkling のモデルを知りません．

### アプリのモデルの一覧から（次のアプリ）

モデルの一覧に **Inkling 2 Mini Uncensored** と **Inkling 2 Mini** が出ます．落とすと下書きのモデルも一緒に来て，Qwen の共通の部品は要りません．起動はほかのモデルと同じです．tail skip の選びは出しません（Qwen の設定）．端末からは:

```sh
sync up --model inkling-2-mini-uncensored            # か inkling-2-mini．API だけなら --api-only
sync down --engine
```

`--model auto`（既定）では，Qwen のモデルが PC に無いときだけ Inkling を起こします．

文脈は 256K です（設定 `context` か `sync up --context` で短くできる）．カードに入らなければエンジンが縮め，起動の記録にそう書きます．

## 速さ

> RTX 5060 Ti 16 GB（PCIe 4.0 x8），Ryzen 5 5600X（6 コア），DDR4 31 GB（2 チャンネル），Linux，CUDA 13.5，2026-11-24 に測定．文脈は 256K，下書きのモデルあり．

コードの答えを 300 トークン書く（greedy）:

| モデル | DSpark なし | DSpark あり | 下書きの当たり |
| --- | ---: | ---: | ---: |
| Inkling 2 Mini Uncensored | 44.2 トークン/秒 | 64.8 トークン/秒 | 71% |
| Inkling 2 Mini（UD-Q4_K_XL） | 40.5 トークン/秒 | 53.0 トークン/秒 | 62% |

| 試し（Uncensored） | 速さ |
| --- | ---: |
| このキットのサーバー経由，短いコードの質問 | 書く 54.7 トークン/秒（下書きの当たり 53%） |
| 2,048 トークンの頼みを読む | 199 トークン/秒（UD-Q4_K_XL: 219） |
| 15,000 トークンの頼みを読み，書く | 173 トークン/秒，書く 50.8 トークン/秒 |
| その会話の次の発言（15,122 トークンを使い回し） | 答えの終わりまで 17.9 秒（使い回しなしは 102 秒） |
| 250,000 トークンの頼みを読む | 平均 47 トークン/秒（88 分），その後 DSpark なしで書く 13.3 トークン/秒 |

## 制限

- Linux と NVIDIA（CUDA 13）だけ．Windows・CUDA 12・Radeon のエンジンには Inkling の道がありません．
- 画像はまだ読めません（AtomicChat の `mmproj`＝画像の部分は使わない）．
- 頼みは 1 つずつ．
- とても長い頼みは読むのが遅い（上の 250K の行）．長い資料は 1 回だけ渡せば，次の発言はそれを使い回します．
- 温度 1.0 では greedy より下書きの当たりが減ります（下書きは greedy で当てる）．
- Qwen の設定（RAM の枠，tail skip，K/V の形式，拒否を減らすベクトル，専門家の学習）は効きません．
- AtomicChat の小さいファイル（AD-IQ3_S，AD-IQ2_M）と Unsloth のほかの大きさは入れていません．

## 困ったとき

| 出たもの | すること |
| --- | --- |
| `Inkling 2 Mini のエンジン（engine-inkling2）が入っていません`（`sync up`） | キットを作って入れる（上） |
| `port … is in use`（`start-inkling.sh`） | Qwen のエンジンが動いています: `sync down --engine`，か `--port <別の番号>` |
| `no 'regex' module` | アプリの Python で流す（`PYTHON=<app>/python/bin/python3`）か `pip install regex` |
| DSpark が無いという警告 | 下書きのモデルをモデルの置き場に置く（`--link-dspark`）か `--dspark <ファイル>` |
| エンジンが止まった | `~/.config/SyncStrata/inkling/engine.log`（`start-inkling.sh`）か `<SYNC_HOME>/run/strata-auto.log`（`sync up`） |

開発者向けの部品の置き場は [英語の版](INKLING2.md#for-developers) にあります．
