# lnako

`lnako` は、なでしこ3 v3.7.24互換を目指す、Zig＋LLVM製のネイティブコンパイラです。通常モードではJavaScriptランタイムを使わず、なでしこソースを独自IRからLLVMへ変換して実行ファイルを生成します。

現在の製品バージョンは `0.0.0-dev` です。互換性の正本は、実装コードの印象やfixtureの数ではなく、[`compat/`](compat/) の機械可読データと検証結果です。

## 対応範囲

標準cnako 527 entryの現行分類は、`native` 523、明示的な `compat-js` 4、`blocked` 0です。これは実装分類であり、全entryの純LLVM AOT実行や3 OS attestationの完了を意味しません。

実行証拠の読み方、canonical台帳とCI artifactの違いは [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md) にまとめています。公式処理系の説明だけでは分かりにくい挙動や、バグの可能性がある挙動は [`docs/COMPATIBILITY_QUIRKS.md`](docs/COMPATIBILITY_QUIRKS.md) から領域別に参照できます。

正式検証環境はmacOS 15 arm64、Ubuntu 24.04 x86_64 GNU、Windows 2025 x86_64 MSVCです。

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

CLIは`build`、`run`、`check`、`test`、`compat report`、`benchmark`に対応します。詳細は`lnako --help`と[開発手順](docs/DEVELOPMENT.md)を参照してください。

## 性能比較

起動、言語コア、数値計算、データ構造、文字列、GC、複合処理から代表9ケースを掲載します。改善余地が残るstring-concatも含めています。コンパイル時間は別表です。

測定対象は `02457ac`、2026年9月7日の[3 OS比較CI](https://github.com/soramikan/lnako/actions/runs/34093414459)です。warmup 3回・測定10回の中央値をmsで示します。小さいほど短時間です。lnakoはReleaseSafeビルド、AOTはO2です。

cnako・gonako・lnakoを正式比較とします。gonakoは3.8.1配布版をハッシュ固定し、自己表示は3.6.0です。以下はLinux CIの代表表です。Windows・macOSを含む全結果は[詳細結果](docs/benchmarks/RESULTS.md)に掲載しています。

| 分野 | ケース | cnako 3.7.24 | gonako | lnako Interpreter | lnako AOT |
| --- | --- | ---: | ---: | ---: | ---: |
| 起動 | `startup-hello` | 107.44 | 6.40 | 2.05 | 1.72 |
| 関数呼出し | `function-call` | 172.14 | 115.27 | 319.98 | 32.42 |
| 浮動小数点 | `nbody` | 157.98 | 47.52 | 397.93 | 15.00 |
| 辞書検索 | `hash-lookup` | 142.47 | 72.37 | 498.49 | 48.68 |
| 文字列連結 | `string-concat` | 115.47 | 22.42 | 57.50 | 28.80 |
| Unicode | `unicode-scan` | 131.16 | 59.09 | 339.71 | 31.36 |
| メモリ・GC | `binary-trees` | 160.93 | 51.33 | 49.29 | 16.98 |
| 単語集計 | `word-count` | 129.80 | 37.40 | 250.90 | 15.69 |
| JSON変換 | `json-transform` | 128.60 | 22.16 | 69.04 | 7.13 |

### コンパイル時間

実行時間と分けて、`compile-stress-medium` のネイティブ実行ファイル生成時間を示します。

| ケース | Linux x86_64 | Windows x86_64 | macOS arm64 |
| --- | ---: | ---: | ---: |
| `compile-stress-medium` | 443.40 | 623.21 | 387.22 |

実行表はprocessの起動・終了を含み、AOTの事前コンパイル時間は含みません。200 ms未満の値は起動時間やrunner負荷の影響を受けやすく、純粋な処理kernelの速度ではありません。配列・辞書の構築など、ケース内のsetupも含みます。

正式20ケースと追加診断12ケース、測定条件・生サンプル・C/Rustの参考値は[詳細結果](docs/benchmarks/RESULTS.md)を参照してください。C/Rustは別言語の参考比較で、正式比較とは分けています。[再測定の手順](benchmarks/README.md)も掲載しています。

## 開発者向けドキュメント

- [アーキテクチャ](docs/ARCHITECTURE.md): コンパイル経路、ランタイム、AOT、QuickJSの責務
- [開発・検証手順](docs/DEVELOPMENT.md): 固定toolchain、fixture、差分検証、コミット方針
- [CI](docs/CI.md): 54-job構成、macOSの5枠制限、artifact、失敗確認
- [互換性概要](docs/COMPATIBILITY.md): 分類、証拠、3 OS attestationの読み方
- [互換性証拠](docs/COMPATIBILITY_EVIDENCE.md): canonical JSONと証拠状態の定義
- [ネイティブプラグインABI](docs/NATIVE_PLUGIN_ABI.md): `lnako_plugin_v1` の公開契約

## ライセンス

MIT License。互換テストで参照するなでしこ3もMIT Licenseです。第三者依存関係は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) に記録しています。
