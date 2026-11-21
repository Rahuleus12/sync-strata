# Credits / 謝辞

[English](#english) | [日本語](#日本語)

## English

### Strata

Sync-Strata's engine, server and app are a fork of [Strata](https://github.com/Niko1221/Strata) by Niko1221 and the Strata contributors (358 author names in upstream's history up to 0.2.7). Thank you all. Sync-Strata would not exist without Strata.

- Upstream: [Niko1221/Strata](https://github.com/Niko1221/Strata) ([contributors](https://github.com/Niko1221/Strata/graphs/contributors))
- The engine with upstream's full history and authors: [hiruhiru2005/sync-strata-engine](https://github.com/hiruhiru2005/sync-strata-engine). `engine/` in this repository is a submodule of it.
- License: MIT. `LICENSE` keeps `Copyright (c) 2026 Niko1221 and the Strata contributors`.

### Other parts

Gyro's trellis types and kernels (agentionai), llama.cpp / ggml, Project Maya, dsh, the fonts and the other bundled parts are listed with their licenses in [LICENSES.md](LICENSES.md).

### The earlier copy of the engine

Until November 2026, `engine/` in this repository was a squashed copy of the engine, without upstream's history and authors (from the first commit, 3b7b861). It is now a submodule of the fork above, which keeps them. The earlier commits are left as they are, so that existing clones and forks keep working.

## 日本語

### Strata

Sync-Strata のエンジン・サーバー・アプリは、Niko1221 さんと Strata の貢献者の皆さんによる [Strata](https://github.com/Niko1221/Strata) のフォークです（0.2.7 までの本家の履歴に 358 の作者名）。皆さんに感謝します。Strata がなければ Sync-Strata はありませんでした。

- 本家: [Niko1221/Strata](https://github.com/Niko1221/Strata)（[貢献者](https://github.com/Niko1221/Strata/graphs/contributors)）
- 本家の履歴と作者を残したエンジン: [hiruhiru2005/sync-strata-engine](https://github.com/hiruhiru2005/sync-strata-engine)。このリポジトリの `engine/` は、そのサブモジュールです。
- ライセンス: MIT。`LICENSE` に `Copyright (c) 2026 Niko1221 and the Strata contributors` を残しています。

### ほかの部品

Gyro のトレリスの型とカーネル（agentionai）、llama.cpp / ggml、Project Maya、dsh、フォントなどの同梱の部品は、ライセンスと一緒に [LICENSES.md](LICENSES.md) に載せています。

### これまでのエンジンの写し

2026 年 11 月まで、このリポジトリの `engine/` は、本家の履歴と作者を残さずにまとめたエンジンの写しでした（最初のコミット 3b7b861 から）。今は、履歴と作者を残した上のフォークを指すサブモジュールです。これまでのコミットは、clone やフォークをしている方の手元が壊れないように、そのまま残しています。
