# ベンチマーク結果 — macos / aarch64

[概要と読み方](RESULTS.md) · [元のJSON](2026-09-07-macos-local.json)

## 測定条件

| 項目 | 値 |
| --- | --- |
| 測定日時（UTC） | 2026-09-06T16:53:08.173Z |
| 測定コミット | aa356cf308902837b02a903c8adf2c3f872684ea（clean） |
| プロファイル | normal / warmup 3回 / 測定 10回 |
| AOT / C / Rust 最適化 | O2 |
| CPU | Apple M1 |
| 論理CPU数 | 8 |
| メモリ | 16.00 GiB |
| OS release | 27.0.0 |
| スイートSHA-256 | 174b77cf2bffd4eb0357ac0471bc0cb9dff2fe70f4e6cbe9c6365914787e8e21 |

### 処理系とコンパイラ

| 処理系 | 区分 | 自己表示バージョン |
| --- | --- | --- |
| lnako | 正式比較 | lnako 0.0.0-dev |
| cnako | 正式比較 | v3.7.24 |
| gonako | 正式比較 | gonako v3.6.0 (darwin/arm64) |
| c | 参考値 | clang version 22.1.8 (https://github.com/llvm/llvm-project ca7933e47d3a3451d81e72ac174dcb5aa28b59d1) |
| rust | 参考値 | rustc 1.95.0 (59807616e 2026-04-14) |

gonako配布版: 3.8.1。配布版とバイナリの自己表示バージョンは別々に記録しています。SHA-256: `dd6218bcb28e3406356b051350530c1082fae62b70399e429fed9de0f6ab9c27`。
[公式配布元](https://github.com/kujirahand/nadesiko3go/releases/download/3.8.1/gonako-3.8.1-darwin-arm64)

## 正式比較：実行時間の中央値

単位は **ms**、小さいほど短時間です。全値にプロセス起動・終了を含み、lnako AOTの事前コンパイルは含みません。† はsteady_stateで中央値200ms未満の測定です。— は未測定・未対応で、0msではありません。

| ケース | cnako | gonako | lnako interpreter | lnako AOT |
| --- | ---: | ---: | ---: | ---: |
| `startup-empty` | 69.04 | 11.83 | 2.43 | 3.93 |
| `startup-hello` | 72.27 | 12.03 | 2.61 | 3.80 |
| `integer-arithmetic` | 94.49 † | 73.66 † | 485.72 | 27.62 † |
| `branch-mix` | 104.99 † | 97.94 † | 684.31 | 39.30 † |
| `function-call` | 106.53 † | 54.78 † | 208.47 | 16.28 † |
| `closure-call` | 98.25 † | 36.88 † | 186.81 † | 7.71 † |
| `recursion` | 1,052.79 | 353.23 | 493.72 | 246.83 |
| `nbody` | 99.60 † | 27.82 † | 258.85 | 8.22 † |
| `array-build` | 80.88 † | 29.68 † | 132.85 † | 6.34 † |
| `array-scan` | 86.27 † | 50.77 † | 460.44 | 11.88 † |
| `hash-lookup` | 94.27 † | 40.19 † | 329.67 | 26.00 † |
| `string-concat` | 77.80 † | 19.56 † | 25.11 † | 51.86 † |
| `string-builder` | 78.70 † | 17.86 † | 38.09 † | 5.28 † |
| `unicode-scan` | 85.43 † | 32.56 † | 226.77 | 15.94 † |
| `sieve` | 89.32 † | 24.96 † | 296.15 | 7.21 † |
| `binary-trees` | 101.49 † | 32.43 † | 29.05 † | 13.78 † |
| `word-count` | 83.98 † | 24.15 † | 168.95 † | 8.91 † |
| `json-transform` | 81.91 † | 18.32 † | 44.32 † | 6.70 † |
| `file-read` | 76.73 † | 12.52 † | 5.34 † | 3.72 † |

## 参考値：C・Rustの実行時間

同じ入力・反復数・期待出力に揃えた別言語の実装です。処理系の正式比較とは区別します。単位はmsで、事前コンパイルを含みません。文字列の反復コピーと可変構築は別のケースとして扱います。

| ケース | C | Rust |
| --- | ---: | ---: |
| `integer-arithmetic` | 3.52 † | 3.77 † |
| `string-concat` | 3.82 † | 4.16 † |
| `string-builder` | 3.17 † | 3.42 † |

## コンパイル時間と実行ファイルサイズ

時間はms、サイズはbytesです。cnako・gonakoのソース実行と、lnako・C・Rustの実行ファイル生成を同一のコンパイル測定として扱いません。

| ケース | 処理系 | 中央値 | P25–P75 | 実行ファイル（bytes） |
| --- | --- | ---: | ---: | ---: |
| `startup-empty` | lnako | 104.49 | 104.26–105.00 | 321,040 |
| `startup-hello` | lnako | 106.89 | 106.40–107.34 | 321,488 |
| `integer-arithmetic` | c | 76.98 | 76.75–77.71 | 33,480 |
| `integer-arithmetic` | rust | 158.27 | 156.87–159.88 | 469,096 |
| `integer-arithmetic` | lnako | 131.41 | 130.42–132.39 | 7,510,144 |
| `branch-mix` | lnako | 143.29 | 142.36–143.68 | 7,510,224 |
| `function-call` | lnako | 126.84 | 126.49–127.17 | 7,510,416 |
| `closure-call` | lnako | 117.17 | 116.62–117.62 | 405,200 |
| `recursion` | lnako | 126.02 | 125.50–126.55 | 7,510,112 |
| `nbody` | lnako | 223.70 | 223.21–224.23 | 7,527,184 |
| `array-build` | lnako | 123.67 | 123.48–124.33 | 7,510,224 |
| `array-scan` | lnako | 130.72 | 130.48–131.20 | 7,510,320 |
| `hash-lookup` | lnako | 134.55 | 133.88–135.10 | 7,526,944 |
| `string-concat` | c | 78.21 | 77.59–78.68 | 33,608 |
| `string-concat` | rust | 153.96 | 152.97–155.60 | 468,664 |
| `string-concat` | lnako | 123.19 | 122.89–123.54 | 7,510,160 |
| `string-builder` | c | 78.22 | 77.82–78.36 | 33,608 |
| `string-builder` | rust | 153.25 | 152.56–153.56 | 468,664 |
| `string-builder` | lnako | 125.58 | 125.23–126.18 | 7,510,288 |
| `unicode-scan` | lnako | 135.37 | 134.55–135.95 | 7,510,416 |
| `sieve` | lnako | 147.12 | 146.75–147.62 | 7,510,256 |
| `binary-trees` | lnako | 142.16 | 141.87–142.45 | 7,527,360 |
| `word-count` | lnako | 150.16 | 149.68–150.68 | 7,527,168 |
| `json-transform` | lnako | 149.41 | 148.71–149.82 | 7,510,480 |
| `file-read` | lnako | 130.82 | 130.59–132.79 | 7,510,224 |
| `compile-stress-medium` | lnako | 482.62 | 480.25–486.85 | 7,526,480 |

## ケースごとのソースと対応範囲

cnakoとlnakoは共通ソースです。gonakoに構文調整が必要な場合は、同じ入力・反復数・期待出力で検証した別ソースをリンクしています。未対応は理由を表示し、成功値へ置き換えません。

| ケース | 共通ソース | gonakoソース | gonakoの対応・調整内容 |
| --- | --- | --- | --- |
| `startup-empty` | [source](../../benchmarks/cases/startup/empty/source.nako3) | [source](../../benchmarks/cases/startup/empty/source.nako3) | 共通ソースで出力一致 |
| `startup-hello` | [source](../../benchmarks/cases/startup/hello/source.nako3) | [source](../../benchmarks/cases/startup/hello/source.nako3) | 共通ソースで出力一致 |
| `integer-arithmetic` | [source](../../benchmarks/cases/core/integer-arithmetic/source.nako3) | [source](../../benchmarks/cases/core/integer-arithmetic/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `branch-mix` | [source](../../benchmarks/cases/core/branch-mix/source.nako3) | [source](../../benchmarks/cases/core/branch-mix/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `function-call` | [source](../../benchmarks/cases/core/function-call/source.nako3) | [source](../../benchmarks/cases/core/function-call/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `closure-call` | [source](../../benchmarks/cases/core/closure-call/source.nako3) | [source](../../benchmarks/cases/core/closure-call/source.nako3) | 共通ソースで出力一致 |
| `recursion` | [source](../../benchmarks/cases/core/recursion/source.nako3) | [source](../../benchmarks/cases/core/recursion/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `nbody` | [source](../../benchmarks/cases/numeric/nbody/source.nako3) | [source](../../benchmarks/cases/numeric/nbody/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `array-build` | [source](../../benchmarks/cases/collections/array-build/source.nako3) | [source](../../benchmarks/cases/collections/array-build/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `array-scan` | [source](../../benchmarks/cases/collections/array-scan/source.nako3) | [source](../../benchmarks/cases/collections/array-scan/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `hash-lookup` | [source](../../benchmarks/cases/collections/hash-lookup/source.nako3) | [source](../../benchmarks/cases/collections/hash-lookup/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `string-concat` | [source](../../benchmarks/cases/strings/string-concat/source.nako3) | [source](../../benchmarks/cases/strings/string-concat/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `string-builder` | [source](../../benchmarks/cases/strings/string-builder/source.nako3) | [source](../../benchmarks/cases/strings/string-builder/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `unicode-scan` | [source](../../benchmarks/cases/strings/unicode-scan/source.nako3) | [source](../../benchmarks/cases/strings/unicode-scan/source.nako3) | 共通ソースで出力一致 |
| `sieve` | [source](../../benchmarks/cases/algorithms/sieve/source.nako3) | [source](../../benchmarks/cases/algorithms/sieve/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `binary-trees` | [source](../../benchmarks/cases/allocation/binary-trees/source.nako3) | [source](../../benchmarks/cases/allocation/binary-trees/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `word-count` | [source](../../benchmarks/cases/applications/word-count/source.nako3) | [source](../../benchmarks/cases/applications/word-count/source.nako3) | 共通ソースで出力一致 |
| `json-transform` | [source](../../benchmarks/cases/serialization/json-transform/source.nako3) | [source](../../benchmarks/cases/serialization/json-transform/source.nako3) | 共通ソースで出力一致 |
| `file-read` | [source](../../benchmarks/cases/io/file-read/source.nako3) | [source](../../benchmarks/cases/io/file-read/gonako.nako3) | gonakoの直接コマンドライン添字構文をARGS配列の代入へ置き換えた同一workload |
| `compile-stress-medium` | [source](../../benchmarks/cases/toolchain/compile-stress-medium/source.nako3) | — | gonakoのbuild/gengoはGo生成・梱包の別工程であり、lnakoのnative compile測定と同じ対象にならない |

## 全測定のばらつき

時間はmsです。IQRはP75−P25、MADは中央値からの絶対偏差の中央値、CVは標準偏差÷平均（%）。生サンプルは元のJSONを参照してください。

| ケース | 処理系 / 経路 | 中央値 | P25–P75 | IQR | MAD | 平均 | 標準偏差 | CV |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `startup-empty` | cnako / run | 69.04 | 68.51–70.57 | 2.06 | 0.61 | 69.57 | 1.43 | 2.1% |
| `startup-empty` | gonako / run | 11.83 | 11.69–11.93 | 0.24 | 0.14 | 11.83 | 0.17 | 1.5% |
| `startup-empty` | lnako / interpreter | 2.43 | 2.41–2.49 | 0.07 | 0.02 | 2.48 | 0.10 | 4.2% |
| `startup-empty` | lnako / compile | 104.49 | 104.26–105.00 | 0.73 | 0.44 | 105.07 | 1.35 | 1.3% |
| `startup-empty` | lnako / aot_run | 3.93 | 3.36–4.25 | 0.89 | 0.53 | 3.92 | 0.66 | 16.9% |
| `startup-hello` | cnako / run | 72.27 | 71.83–73.05 | 1.21 | 0.61 | 72.70 | 1.38 | 1.9% |
| `startup-hello` | gonako / run | 12.03 | 11.95–12.22 | 0.27 | 0.16 | 12.12 | 0.35 | 2.9% |
| `startup-hello` | lnako / interpreter | 2.61 | 2.59–2.69 | 0.10 | 0.05 | 2.66 | 0.14 | 5.3% |
| `startup-hello` | lnako / compile | 106.89 | 106.40–107.34 | 0.94 | 0.50 | 106.88 | 0.55 | 0.5% |
| `startup-hello` | lnako / aot_run | 3.80 | 3.36–4.53 | 1.17 | 0.57 | 3.90 | 0.61 | 15.6% |
| `integer-arithmetic` | cnako / run | 94.49 | 93.97–95.68 | 1.71 | 0.82 | 95.12 | 1.77 | 1.9% |
| `integer-arithmetic` | gonako / run | 73.66 | 73.43–73.97 | 0.54 | 0.28 | 73.74 | 0.34 | 0.5% |
| `integer-arithmetic` | c / compile | 76.98 | 76.75–77.71 | 0.96 | 0.41 | 77.24 | 0.99 | 1.3% |
| `integer-arithmetic` | c / run | 3.52 | 3.10–3.87 | 0.78 | 0.44 | 3.49 | 0.43 | 12.3% |
| `integer-arithmetic` | rust / compile | 158.27 | 156.87–159.88 | 3.01 | 1.65 | 158.95 | 2.47 | 1.6% |
| `integer-arithmetic` | rust / run | 3.77 | 3.38–4.38 | 1.00 | 0.54 | 3.84 | 0.55 | 14.5% |
| `integer-arithmetic` | lnako / interpreter | 485.72 | 484.85–486.67 | 1.82 | 0.93 | 486.29 | 2.05 | 0.4% |
| `integer-arithmetic` | lnako / compile | 131.41 | 130.42–132.39 | 1.97 | 1.03 | 131.70 | 1.53 | 1.2% |
| `integer-arithmetic` | lnako / aot_run | 27.62 | 27.43–27.74 | 0.30 | 0.14 | 27.59 | 0.16 | 0.6% |
| `branch-mix` | cnako / run | 104.99 | 104.63–105.92 | 1.29 | 0.76 | 105.27 | 0.87 | 0.8% |
| `branch-mix` | gonako / run | 97.94 | 97.83–98.21 | 0.38 | 0.12 | 98.09 | 0.37 | 0.4% |
| `branch-mix` | lnako / interpreter | 684.31 | 683.66–684.98 | 1.32 | 0.73 | 685.37 | 2.71 | 0.4% |
| `branch-mix` | lnako / compile | 143.29 | 142.36–143.68 | 1.32 | 0.62 | 143.18 | 0.84 | 0.6% |
| `branch-mix` | lnako / aot_run | 39.30 | 39.11–39.40 | 0.29 | 0.14 | 39.26 | 0.18 | 0.5% |
| `function-call` | cnako / run | 106.53 | 105.73–108.36 | 2.63 | 1.22 | 107.53 | 2.61 | 2.4% |
| `function-call` | gonako / run | 54.78 | 54.55–55.14 | 0.59 | 0.27 | 54.89 | 0.43 | 0.8% |
| `function-call` | lnako / interpreter | 208.47 | 207.90–209.02 | 1.12 | 0.61 | 208.43 | 0.87 | 0.4% |
| `function-call` | lnako / compile | 126.84 | 126.49–127.17 | 0.68 | 0.41 | 126.87 | 0.50 | 0.4% |
| `function-call` | lnako / aot_run | 16.28 | 16.16–16.41 | 0.25 | 0.15 | 16.30 | 0.19 | 1.2% |
| `closure-call` | cnako / run | 98.25 | 97.32–99.56 | 2.24 | 1.13 | 98.81 | 1.95 | 2.0% |
| `closure-call` | gonako / run | 36.88 | 36.58–37.05 | 0.47 | 0.27 | 36.93 | 0.40 | 1.1% |
| `closure-call` | lnako / interpreter | 186.81 | 186.24–187.19 | 0.95 | 0.53 | 186.82 | 0.70 | 0.4% |
| `closure-call` | lnako / compile | 117.17 | 116.62–117.62 | 1.00 | 0.61 | 117.17 | 0.76 | 0.6% |
| `closure-call` | lnako / aot_run | 7.71 | 7.51–8.29 | 0.78 | 0.29 | 7.99 | 0.66 | 8.3% |
| `recursion` | cnako / run | 1,052.79 | 1,043.55–1,062.61 | 19.06 | 10.75 | 1,053.51 | 15.19 | 1.4% |
| `recursion` | gonako / run | 353.23 | 352.78–354.69 | 1.92 | 1.37 | 353.73 | 1.78 | 0.5% |
| `recursion` | lnako / interpreter | 493.72 | 492.24–494.15 | 1.91 | 1.28 | 493.84 | 1.99 | 0.4% |
| `recursion` | lnako / compile | 126.02 | 125.50–126.55 | 1.04 | 0.54 | 126.27 | 1.29 | 1.0% |
| `recursion` | lnako / aot_run | 246.83 | 245.82–247.31 | 1.49 | 0.80 | 246.87 | 1.69 | 0.7% |
| `nbody` | cnako / run | 99.60 | 99.02–100.17 | 1.15 | 0.62 | 99.57 | 0.84 | 0.8% |
| `nbody` | gonako / run | 27.82 | 27.72–27.87 | 0.15 | 0.09 | 27.84 | 0.23 | 0.8% |
| `nbody` | lnako / interpreter | 258.85 | 258.11–260.25 | 2.14 | 0.97 | 259.35 | 1.78 | 0.7% |
| `nbody` | lnako / compile | 223.70 | 223.21–224.23 | 1.02 | 0.59 | 223.79 | 0.96 | 0.4% |
| `nbody` | lnako / aot_run | 8.22 | 7.79–8.78 | 0.98 | 0.48 | 8.49 | 0.93 | 11.0% |
| `array-build` | cnako / run | 80.88 | 80.30–81.84 | 1.55 | 0.86 | 80.97 | 1.24 | 1.5% |
| `array-build` | gonako / run | 29.68 | 29.40–30.02 | 0.62 | 0.38 | 29.63 | 0.47 | 1.6% |
| `array-build` | lnako / interpreter | 132.85 | 132.34–133.27 | 0.93 | 0.48 | 132.92 | 0.62 | 0.5% |
| `array-build` | lnako / compile | 123.67 | 123.48–124.33 | 0.84 | 0.30 | 123.91 | 0.57 | 0.5% |
| `array-build` | lnako / aot_run | 6.34 | 6.14–7.39 | 1.25 | 0.57 | 6.73 | 0.92 | 13.7% |
| `array-scan` | cnako / run | 86.27 | 85.65–86.95 | 1.30 | 0.75 | 86.32 | 1.26 | 1.5% |
| `array-scan` | gonako / run | 50.77 | 50.56–51.00 | 0.44 | 0.24 | 50.84 | 0.36 | 0.7% |
| `array-scan` | lnako / interpreter | 460.44 | 460.00–460.73 | 0.73 | 0.40 | 460.40 | 0.46 | 0.1% |
| `array-scan` | lnako / compile | 130.72 | 130.48–131.20 | 0.72 | 0.43 | 130.78 | 0.50 | 0.4% |
| `array-scan` | lnako / aot_run | 11.88 | 11.85–12.14 | 0.30 | 0.10 | 12.05 | 0.36 | 3.0% |
| `hash-lookup` | cnako / run | 94.27 | 92.38–95.10 | 2.73 | 1.65 | 94.31 | 2.17 | 2.3% |
| `hash-lookup` | gonako / run | 40.19 | 39.98–41.65 | 1.67 | 0.33 | 40.68 | 1.11 | 2.7% |
| `hash-lookup` | lnako / interpreter | 329.67 | 328.88–331.05 | 2.17 | 1.15 | 330.24 | 1.97 | 0.6% |
| `hash-lookup` | lnako / compile | 134.55 | 133.88–135.10 | 1.22 | 0.64 | 134.60 | 0.85 | 0.6% |
| `hash-lookup` | lnako / aot_run | 26.00 | 25.73–26.30 | 0.57 | 0.30 | 26.07 | 0.44 | 1.7% |
| `string-concat` | cnako / run | 77.80 | 77.11–78.77 | 1.66 | 0.96 | 78.24 | 1.40 | 1.8% |
| `string-concat` | gonako / run | 19.56 | 19.43–19.93 | 0.50 | 0.20 | 19.66 | 0.31 | 1.6% |
| `string-concat` | c / compile | 78.21 | 77.59–78.68 | 1.09 | 0.61 | 78.30 | 0.81 | 1.0% |
| `string-concat` | c / run | 3.82 | 3.66–4.45 | 0.79 | 0.25 | 4.13 | 0.64 | 15.5% |
| `string-concat` | rust / compile | 153.96 | 152.97–155.60 | 2.63 | 1.35 | 154.82 | 2.67 | 1.7% |
| `string-concat` | rust / run | 4.16 | 3.72–4.79 | 1.07 | 0.53 | 4.37 | 0.80 | 18.3% |
| `string-concat` | lnako / interpreter | 25.11 | 24.98–25.41 | 0.42 | 0.19 | 25.17 | 0.26 | 1.0% |
| `string-concat` | lnako / compile | 123.19 | 122.89–123.54 | 0.65 | 0.37 | 123.21 | 0.50 | 0.4% |
| `string-concat` | lnako / aot_run | 51.86 | 51.69–53.15 | 1.46 | 0.31 | 53.47 | 3.48 | 6.5% |
| `string-builder` | cnako / run | 78.70 | 77.82–79.40 | 1.58 | 0.85 | 78.78 | 1.22 | 1.6% |
| `string-builder` | gonako / run | 17.86 | 17.63–18.02 | 0.39 | 0.18 | 17.80 | 0.23 | 1.3% |
| `string-builder` | c / compile | 78.22 | 77.82–78.36 | 0.54 | 0.26 | 78.10 | 0.48 | 0.6% |
| `string-builder` | c / run | 3.17 | 3.00–3.51 | 0.51 | 0.24 | 3.19 | 0.34 | 10.5% |
| `string-builder` | rust / compile | 153.25 | 152.56–153.56 | 1.00 | 0.61 | 153.77 | 1.91 | 1.2% |
| `string-builder` | rust / run | 3.42 | 3.07–4.04 | 0.97 | 0.48 | 3.60 | 0.65 | 18.0% |
| `string-builder` | lnako / interpreter | 38.09 | 37.98–38.37 | 0.39 | 0.19 | 38.24 | 0.38 | 1.0% |
| `string-builder` | lnako / compile | 125.58 | 125.23–126.18 | 0.95 | 0.53 | 125.75 | 0.74 | 0.6% |
| `string-builder` | lnako / aot_run | 5.28 | 4.97–5.74 | 0.78 | 0.46 | 5.45 | 0.62 | 11.4% |
| `unicode-scan` | cnako / run | 85.43 | 84.77–85.78 | 1.01 | 0.59 | 85.65 | 1.55 | 1.8% |
| `unicode-scan` | gonako / run | 32.56 | 32.40–32.85 | 0.44 | 0.27 | 32.65 | 0.50 | 1.5% |
| `unicode-scan` | lnako / interpreter | 226.77 | 226.27–227.02 | 0.75 | 0.45 | 226.79 | 0.61 | 0.3% |
| `unicode-scan` | lnako / compile | 135.37 | 134.55–135.95 | 1.39 | 0.72 | 135.66 | 2.00 | 1.5% |
| `unicode-scan` | lnako / aot_run | 15.94 | 15.58–16.26 | 0.69 | 0.39 | 16.15 | 0.71 | 4.4% |
| `sieve` | cnako / run | 89.32 | 88.89–89.78 | 0.90 | 0.44 | 89.55 | 1.00 | 1.1% |
| `sieve` | gonako / run | 24.96 | 24.67–25.01 | 0.33 | 0.19 | 24.86 | 0.25 | 1.0% |
| `sieve` | lnako / interpreter | 296.15 | 295.74–297.27 | 1.53 | 0.68 | 296.81 | 1.66 | 0.6% |
| `sieve` | lnako / compile | 147.12 | 146.75–147.62 | 0.87 | 0.50 | 147.54 | 1.25 | 0.9% |
| `sieve` | lnako / aot_run | 7.21 | 6.81–8.67 | 1.86 | 0.49 | 7.69 | 1.05 | 13.6% |
| `binary-trees` | cnako / run | 101.49 | 101.19–102.10 | 0.91 | 0.34 | 101.69 | 0.63 | 0.6% |
| `binary-trees` | gonako / run | 32.43 | 32.28–32.61 | 0.34 | 0.19 | 32.46 | 0.20 | 0.6% |
| `binary-trees` | lnako / interpreter | 29.05 | 28.94–29.16 | 0.22 | 0.12 | 29.05 | 0.12 | 0.4% |
| `binary-trees` | lnako / compile | 142.16 | 141.87–142.45 | 0.59 | 0.30 | 142.72 | 1.78 | 1.2% |
| `binary-trees` | lnako / aot_run | 13.78 | 13.61–13.82 | 0.20 | 0.13 | 13.80 | 0.24 | 1.7% |
| `word-count` | cnako / run | 83.98 | 83.83–84.47 | 0.64 | 0.36 | 84.16 | 0.65 | 0.8% |
| `word-count` | gonako / run | 24.15 | 24.09–24.29 | 0.20 | 0.09 | 24.20 | 0.22 | 0.9% |
| `word-count` | lnako / interpreter | 168.95 | 168.65–169.38 | 0.73 | 0.38 | 169.19 | 1.36 | 0.8% |
| `word-count` | lnako / compile | 150.16 | 149.68–150.68 | 1.00 | 0.53 | 150.21 | 0.85 | 0.6% |
| `word-count` | lnako / aot_run | 8.91 | 8.62–10.00 | 1.38 | 0.38 | 9.49 | 1.16 | 12.2% |
| `json-transform` | cnako / run | 81.91 | 81.68–82.81 | 1.12 | 0.55 | 82.56 | 1.75 | 2.1% |
| `json-transform` | gonako / run | 18.32 | 18.15–18.67 | 0.52 | 0.21 | 18.56 | 0.58 | 3.1% |
| `json-transform` | lnako / interpreter | 44.32 | 44.11–44.59 | 0.47 | 0.23 | 44.34 | 0.24 | 0.5% |
| `json-transform` | lnako / compile | 149.41 | 148.71–149.82 | 1.11 | 0.54 | 149.30 | 0.57 | 0.4% |
| `json-transform` | lnako / aot_run | 6.70 | 6.22–7.49 | 1.28 | 0.60 | 7.09 | 1.12 | 15.8% |
| `file-read` | cnako / run | 76.73 | 75.98–77.63 | 1.65 | 0.79 | 77.05 | 1.42 | 1.8% |
| `file-read` | gonako / run | 12.52 | 12.46–13.05 | 0.59 | 0.09 | 12.75 | 0.44 | 3.4% |
| `file-read` | lnako / interpreter | 5.34 | 5.26–5.45 | 0.19 | 0.09 | 5.35 | 0.10 | 1.9% |
| `file-read` | lnako / compile | 130.82 | 130.59–132.79 | 2.20 | 0.68 | 131.62 | 1.54 | 1.2% |
| `file-read` | lnako / aot_run | 3.72 | 3.27–4.24 | 0.97 | 0.50 | 3.84 | 0.68 | 17.6% |
| `compile-stress-medium` | lnako / compile | 482.62 | 480.25–486.85 | 6.60 | 2.48 | 483.57 | 3.60 | 0.7% |

20ケース・108測定行で期待出力を確認済みです。共有CI・OS・CPUやページキャッシュの影響があるため、環境間の直接順位付けや総合スコアには使用しません。
