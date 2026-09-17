# lnako

[![CI](https://img.shields.io/github/actions/workflow/status/soramikan/lnako/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/soramikan/lnako/actions/workflows/ci.yml)
[![バージョン](https://img.shields.io/github/v/release/soramikan/lnako?style=flat-square&label=%E3%83%90%E3%83%BC%E3%82%B8%E3%83%A7%E3%83%B3)](https://github.com/soramikan/lnako/releases)
[![なでしこ3バージョン](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Fsoramikan%2Flnako%2Fmain%2Fcompat%2Fv3.7.24%2Fsummary.json&query=%24.baseline.tag&style=flat-square&label=%E3%81%AA%E3%81%A7%E3%81%97%E3%81%933%E3%83%90%E3%83%BC%E3%82%B8%E3%83%A7%E3%83%B3)](https://github.com/soramikan/lnako/blob/main/compat/v3.7.24/summary.json)
[![ライセンス](https://img.shields.io/github/license/soramikan/lnako?style=flat-square&label=%E3%83%A9%E3%82%A4%E3%82%BB%E3%83%B3%E3%82%B9)](https://github.com/soramikan/lnako/blob/main/LICENSE)

`lnako` は、日本語プログラミング言語「なでしこ3」を高速に実行し、単一のネイティブ実行ファイルへコンパイルできるCLIツールです。公式なでしこ3（v3.7.24）互換を基準とし、macOS（arm64）・Linux（x86_64）・Windows（x86_64）に対応します。大学入学共通テスト手順記述標準言語（DNCL / DNCL2）の実行・ビルドにも対応しています。

## インストール

### macOS（Homebrew）

[Homebrew tap](https://github.com/soramikan/homebrew-tap) から手軽に導入できます。

```sh
brew tap soramikan/tap
brew install lnako
lnako --version
```

### Linux・Windows・アーカイブ導入

[GitHub Releases](https://github.com/soramikan/lnako/releases) から最新の配布アーカイブをダウンロードし、展開して `bin` をPATHに追加してください。

| 配布版 | 特徴・用途 |
| --- | --- |
| standard | 軽量版。スクリプト実行（`run`）や構文検査（`check`）向け。コンパイル用LLVMは後から追加可能 |
| full（`-full`） | LLVM/LLD同梱版。追加ダウンロードなしで即座にネイティブ実行ファイルを生成可能 |

詳細なOS別手順やハッシュ検証は[使い始める](docs/GETTING_STARTED.md)を参照してください。

## 使い方

`hello.nako3` を作成します。

```nako3
「こんにちは」と表示する。
```

```sh
lnako check hello.nako3          # 構文・意味をチェック
lnako run hello.nako3            # スクリプトとして直接実行
lnako toolchain install          # standard版/Homebrewでコンパイルを行う場合に初回のみ実行
lnako build hello.nako3 -o hello -O2 # ネイティブ実行ファイルを生成（Windowsは -o hello.exe）
./hello                          # 外部ランタイム不要で高速動作
```

生成した実行ファイルは、lnakoやNode.js等のランタイム不要で単体動作します。JavaScript固有命令を使う場合は `lnako run hello.nako3 --compat-js` を指定します。詳細は[互換モード](docs/compatibility/COMPAT_JS.md)を参照してください。

## 対応範囲

標準cnako 527 entryの実装分類は `native` 523、`compat-js` 4、`blocked` 0です。詳細は[互換性と保証範囲](docs/COMPATIBILITY.md)、[未対応境界・後続課題](docs/TODO.md)、[公式処理系との挙動差](docs/COMPATIBILITY_QUIRKS.md)を確認してください。検証状態の正本は [`compat/`](compat/) です。
また、なでしこ3向け共通パッケージシステム仕様案を [`docs/package-system/SPECIFICATION.md`](docs/package-system/SPECIFICATION.md) および [`tools/package-system/`](tools/package-system/) で提案・実装しています。

## 性能比較

2026年9月9日（JST）の[リリース候補比較CI](https://github.com/soramikan/lnako/actions/runs/34246129122)（commit `5dcf585`、Linux）の結果です。公式cnako比で起動時間は約40〜60倍高速化され、計算・処理も大幅に短縮されます。

| 分野 | ケース | cnako | gonako | lnako Interpreter | cnako比 | lnako AOT | cnako比 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 起動 | `startup-hello` | 106.54 | 6.61 | 2.49 | 42.77倍 | 1.79 | 59.68倍 |
| 関数呼出し | `function-call` | 169.74 | 116.86 | 310.44 | 0.55倍 | 33.02 | 5.14倍 |
| 浮動小数点 | `nbody` | 158.66 | 47.09 | 391.49 | 0.41倍 | 15.05 | 10.54倍 |
| 辞書検索 | `hash-lookup` | 142.23 | 72.51 | 481.68 | 0.30倍 | 50.36 | 2.82倍 |
| 文字列連結 | `string-concat` | 117.76 | 22.75 | 56.51 | 2.08倍 | 28.21 | 4.17倍 |
| Unicode | `unicode-scan` | 128.67 | 58.46 | 337.20 | 0.38倍 | 29.53 | 4.36倍 |
| メモリ・GC | `binary-trees` | 163.48 | 51.74 | 48.76 | 3.35倍 | 17.20 | 9.51倍 |
| 単語集計 | `word-count` | 125.37 | 37.12 | 251.92 | 0.50倍 | 15.20 | 8.25倍 |
| JSON変換 | `json-transform` | 128.48 | 22.97 | 67.21 | 1.91倍 | 7.12 | 18.03倍 |

全19ケース、各OSの測定値、コンパイル時間の詳細は[詳細結果](docs/benchmarks/RESULTS.md)に掲載しています。

## 開発者向け

lnako自体のビルドや機能開発については[開発・検証手順](docs/DEVELOPMENT.md)を参照してください。

- [アーキテクチャ](docs/ARCHITECTURE.md)・[ネイティブプラグインABI](docs/NATIVE_PLUGIN_ABI.md)
- [CIと検証](docs/CI.md)・[互換性証拠](docs/COMPATIBILITY_EVIDENCE.md)
- [配布とリリース手順](docs/RELEASE.md)・[ベンチマーク再測定](benchmarks/README.md)

## ライセンス

MIT License。第三者依存関係は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)に記録しています。
