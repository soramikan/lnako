# lnako

`lnako` は、なでしこ3 v3.7.24互換を目指す、Zig＋LLVM製のネイティブコンパイラです。通常モードではJavaScriptランタイムを使わず、なでしこソースを独自IRからLLVMへ変換して実行ファイルを生成します。

現在の製品バージョンは `0.0.0-dev` です。互換性の正本は、実装コードの印象やfixtureの数ではなく、[`compat/`](compat/) の機械可読データと検証結果です。

## 対応範囲

標準cnako 527 entryの現行分類は、`native` 523、明示的な `compat-js` 4、`blocked` 0です。これは実装分類であり、全entryの純LLVM AOT実行や3 OS attestationの完了を意味しません。

実行証拠の読み方、canonical台帳とCI artifactの違いは [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md) にまとめています。公式処理系の説明だけでは分かりにくい挙動や、バグの可能性がある挙動は [`docs/COMPATIBILITY_QUIRKS.md`](docs/COMPATIBILITY_QUIRKS.md) から領域別に参照できます。

正式に検証する対象OSは次の3つです。

| OS | CPU | 用途 |
| --- | --- | --- |
| macOS 15 | arm64 | macOSネイティブ実行・AOT |
| Ubuntu 24.04 | x86_64 GNU | Linuxネイティブ実行・AOT |
| Windows 2025 | x86_64 MSVC | Windowsネイティブ実行・AOT |

## 必要なツール

| ツール | 固定版 | 用途 |
| --- | --- | --- |
| Zig | 0.16.0 | コンパイラ・ランタイム・テスト |
| LLVM / LLD | 22.1.8（ベースライン）; 21.x–23.x 実行時対応 | LLVM IR生成・最適化・リンク |
| Node.js | 24.15.0 | 公式処理系との差分テストのみ |
| QuickJS | 2026-06-04 | 明示的な `--compat-js` 経路のみ |

Zig、LLVM、LLD、Node.jsを通常の生成物へ組み込むことはありません。固定toolchainの取得と検証は開発環境・CI向けです。

## ビルドと実行

```sh
zig build
zig build test
zig build run -- --help

zig build run -- check program.nako3
zig build run -- run program.nako3
zig build run -- test tests/
zig build run -- build program.nako3 -o program -O2
```

LLVM/LLDの場所を明示する場合は `LNAKO_LLVM_DIR` または `LNAKO_LLVM_LIBRARY` を使います。詳細なセットアップと検証順序は [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) を参照してください。

## QuickJS互換モード

JavaScript固有の4命令は通常モードへ混入させず、明示的な互換モードだけで実行します。

```sh
node tools/setup_quickjs.mjs
zig build -Dcompat-js=true
zig build -Dcompat-js=true test
zig build -Dcompat-js=true run -- run program.nako3 --compat-js
```

QuickJS経路の範囲と証拠は [`docs/compatibility/COMPAT_JS.md`](docs/compatibility/COMPAT_JS.md) にあります。

## CLI

```text
lnako build <file.nako3> -o <output> [-O0|-O1|-O2|-O3] [--emit exe|obj|llvm-ir]
lnako run <file.nako3> [--compat-js] -- <program arguments>
lnako check <file.nako3>
lnako test <file-or-directory>
lnako compat report
lnako benchmark
```

`build`、`run`、`check`、`test`、`compat report`、`benchmark`、ヘルプ、バージョン表示を利用できます。`benchmark`の結果形式やRelease向けの配布手順は、利用者向け導入手順とは分けて [`docs/RELEASE.md`](docs/RELEASE.md) に記録しています。

## 性能比較

cnako・gonako・lnakoを正式比較、C・Rustを参考値として測定します。代表値は2026年9月6日（JST）、Linux x86_64のCI（AMD EPYC 7763 64-Core Processor、論理4 CPU）で、warmup 3回・測定10回の**中央値（ms、小さいほど短時間）**です。lnako AOT・C・RustはO2、測定コミットは `d072a54` です。

| ケース | cnako 3.7.24 | gonako 3.8.1配布版 | lnako解釈 | lnako AOT | C（参考） | Rust（参考） |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 整数演算 | 132.95 | 132.82 | 851.73 | 63.15 | 2.08 | 2.25 |
| 文字列の反復コピー | 119.80 | 22.92 | 60.65 | 53.63 | 2.27 | 2.49 |
| 文字列構築 | 123.65 | 22.96 | 74.28 | 9.89 | 1.53 | 1.83 |
| 辞書検索 | 151.00 | 74.05 | 577.08 | 4,511.79 | — | — |

実行時間は起動・終了を含み、事前コンパイルは含みません。200ms未満は起動の影響を受けやすく、辞書検索のようにAOTが遅いケースもあります。—は未測定です。gonakoの構文調整、自己表示バージョンと配布版の差、C・Rustの実装・コンパイラ条件は[詳細結果](docs/benchmarks/RESULTS.md)を参照してください。[実行方法](benchmarks/README.md)も掲載しています。

## 開発者向けドキュメント

- [アーキテクチャ](docs/ARCHITECTURE.md): コンパイル経路、ランタイム、AOT、QuickJSの責務
- [開発・検証手順](docs/DEVELOPMENT.md): 固定toolchain、fixture、差分検証、コミット方針
- [CI](docs/CI.md): 54-job構成、macOSの5枠制限、artifact、失敗確認
- [互換性概要](docs/COMPATIBILITY.md): 分類、証拠、3 OS attestationの読み方
- [互換性証拠](docs/COMPATIBILITY_EVIDENCE.md): canonical JSONと証拠状態の定義
- [ネイティブプラグインABI](docs/NATIVE_PLUGIN_ABI.md): `lnako_plugin_v1` の公開契約

## ライセンス

MIT License。互換テストで参照するなでしこ3もMIT Licenseです。第三者依存関係は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) に記録しています。
