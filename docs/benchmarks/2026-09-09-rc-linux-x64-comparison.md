# ベンチマーク結果 — linux / x86_64

[概要と読み方](RESULTS.md) · [元のJSON](2026-09-09-rc-linux-x64-comparison.json)

## 測定条件

| 項目 | 値 |
| --- | --- |
| 測定日時（UTC） | 2026-09-08T15:46:46.794Z |
| 測定コミット | 5dcf585f4db394206fb5480ef6b184d3138c6daf（clean） |
| プロファイル | smoke / warmup 1回 / 測定 3回 |
| AOT / C / Rust 最適化 | O2 |
| CPU | AMD EPYC 7763 64-Core Processor |
| 論理CPU数 | 4 |
| メモリ | 15.61 GiB |
| OS release | 6.17.0-1022-azure |
| スイートSHA-256 | 174b77cf2bffd4eb0357ac0471bc0cb9dff2fe70f4e6cbe9c6365914787e8e21 |

### 処理系とコンパイラ

| 処理系 | 区分 | 自己表示バージョン |
| --- | --- | --- |
| lnako | 正式比較 | lnako 0.1.0 |
| cnako | 正式比較 | v3.7.24 |
| gonako | 正式比較 | gonako v3.6.0 (linux/amd64) |
| c | 参考値 | clang version 22.1.8 (https://github.com/llvm/llvm-project ca7933e47d3a3451d81e72ac174dcb5aa28b59d1) |
| rust | 参考値 | rustc 1.98.0 (88d9e12ae 2026-08-18) |

gonako配布版: 3.8.1。配布版とバイナリの自己表示バージョンは別々に記録しています。SHA-256: `1dcac44e6a9b1b42587d7824010dda5ce8e726521750c2ae18f1313acddfefa9`。
[公式配布元](https://github.com/kujirahand/nadesiko3go/releases/download/3.8.1/gonako-3.8.1-linux-amd64)

## 正式比較：実行時間の中央値

単位は **ms**、小さいほど短時間です。全値にプロセス起動・終了を含み、lnako AOTの事前コンパイルは含みません。† はsteady_stateで中央値200ms未満の測定です。— は未測定・未対応で、0msではありません。

| ケース | cnako | gonako | lnako interpreter | lnako AOT |
| --- | ---: | ---: | ---: | ---: |
| `startup-empty` | 104.70 | 7.60 | 2.24 | 1.79 |
| `startup-hello` | 106.54 | 6.61 | 2.49 | 1.79 |
| `integer-arithmetic` | 129.87 † | 133.42 † | 719.50 | 57.73 † |
| `branch-mix` | 137.35 † | 166.69 † | 1,018.01 | 75.35 † |
| `function-call` | 169.74 † | 116.86 † | 310.44 | 33.02 † |
| `closure-call` | 153.65 † | 70.97 † | 268.39 | 9.34 † |
| `recursion` | 1,593.65 | 809.52 | 729.96 | 222.11 |
| `nbody` | 158.66 † | 47.09 † | 391.49 | 15.05 † |
| `array-build` | 121.89 † | 52.96 † | 232.65 | 6.00 † |
| `array-scan` | 129.47 † | 108.07 † | 696.29 | 26.62 † |
| `hash-lookup` | 142.23 † | 72.51 † | 481.68 | 50.36 † |
| `string-concat` | 117.76 † | 22.75 † | 56.51 † | 28.21 † |
| `string-builder` | 116.03 † | 21.93 † | 66.10 † | 3.99 † |
| `unicode-scan` | 128.67 † | 58.46 † | 337.20 | 29.53 † |
| `sieve` | 129.57 † | 39.86 † | 439.60 | 14.41 † |
| `binary-trees` | 163.48 † | 51.74 † | 48.76 † | 17.20 † |
| `word-count` | 125.37 † | 37.12 † | 251.92 | 15.20 † |
| `json-transform` | 128.48 † | 22.97 † | 67.21 † | 7.12 † |
| `file-read` | 118.63 † | 8.47 † | 6.79 † | 2.09 † |

## 参考値：C・Rustの実行時間

同じ入力・反復数・期待出力に揃えた別言語の実装です。処理系の正式比較とは区別します。単位はmsで、事前コンパイルを含みません。文字列の反復コピーと可変構築は別のケースとして扱います。

| ケース | C | Rust |
| --- | ---: | ---: |
| `integer-arithmetic` | 2.23 † | 2.36 † |
| `string-concat` | 2.29 † | 2.44 † |
| `string-builder` | 1.56 † | 1.73 † |

## コンパイル時間と実行ファイルサイズ

時間はms、サイズはbytesです。cnako・gonakoのソース実行と、lnako・C・Rustの実行ファイル生成を同一のコンパイル測定として扱いません。

| ケース | 処理系 | 中央値 | P25–P75 | 実行ファイル（bytes） |
| --- | --- | ---: | ---: | ---: |
| `startup-empty` | lnako | 58.28 | 57.39–58.47 | 441,712 |
| `startup-hello` | lnako | 61.63 | 60.62–61.85 | 451,600 |
| `integer-arithmetic` | c | 45.37 | 45.13–45.56 | 16,040 |
| `integer-arithmetic` | rust | 143.08 | 142.71–143.41 | 4,515,232 |
| `integer-arithmetic` | lnako | 94.46 | 93.80–94.61 | 638,760 |
| `branch-mix` | lnako | 103.48 | 103.48–103.81 | 688,984 |
| `function-call` | lnako | 89.30 | 88.82–89.43 | 638,960 |
| `closure-call` | lnako | 84.45 | 84.11–84.58 | 540,784 |
| `recursion` | lnako | 81.29 | 81.00–81.55 | 683,672 |
| `nbody` | lnako | 207.09 | 206.86–207.76 | 710,328 |
| `array-build` | lnako | 83.48 | 83.12–84.58 | 640,040 |
| `array-scan` | lnako | 98.39 | 97.45–98.43 | 641,712 |
| `hash-lookup` | lnako | 104.16 | 104.02–104.19 | 657,776 |
| `string-concat` | c | 43.96 | 43.49–44.13 | 16,192 |
| `string-concat` | rust | 133.95 | 133.91–134.09 | 4,514,368 |
| `string-concat` | lnako | 79.19 | 79.03–79.23 | 644,208 |
| `string-builder` | c | 43.91 | 43.90–44.02 | 16,192 |
| `string-builder` | rust | 132.08 | 132.04–132.34 | 4,514,272 |
| `string-builder` | lnako | 92.12 | 91.75–92.32 | 8,033,560 |
| `unicode-scan` | lnako | 110.16 | 110.07–110.62 | 8,029,296 |
| `sieve` | lnako | 112.67 | 112.66–113.16 | 697,976 |
| `binary-trees` | lnako | 119.06 | 118.87–119.48 | 695,320 |
| `word-count` | lnako | 132.19 | 131.95–132.89 | 8,036,720 |
| `json-transform` | lnako | 136.22 | 136.18–136.26 | 8,033,048 |
| `file-read` | lnako | 108.28 | 107.72–109.04 | 8,029,192 |

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

## 全測定のばらつき

時間はmsです。IQRはP75−P25、MADは中央値からの絶対偏差の中央値、CVは標準偏差÷平均（%）。生サンプルは元のJSONを参照してください。

| ケース | 処理系 / 経路 | 中央値 | P25–P75 | IQR | MAD | 平均 | 標準偏差 | CV |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `startup-empty` | cnako / run | 104.70 | 102.92–108.80 | 5.88 | 3.57 | 106.25 | 4.93 | 4.6% |
| `startup-empty` | gonako / run | 7.60 | 7.43–7.84 | 0.42 | 0.35 | 7.65 | 0.34 | 4.5% |
| `startup-empty` | lnako / interpreter | 2.24 | 2.19–2.47 | 0.28 | 0.09 | 2.36 | 0.24 | 10.2% |
| `startup-empty` | lnako / compile | 58.28 | 57.39–58.47 | 1.09 | 0.39 | 57.81 | 0.94 | 1.6% |
| `startup-empty` | lnako / aot_run | 1.79 | 1.76–1.81 | 0.05 | 0.04 | 1.78 | 0.04 | 2.3% |
| `startup-hello` | cnako / run | 106.54 | 106.47–107.94 | 1.47 | 0.14 | 107.43 | 1.36 | 1.3% |
| `startup-hello` | gonako / run | 6.61 | 6.47–6.70 | 0.23 | 0.18 | 6.58 | 0.19 | 2.9% |
| `startup-hello` | lnako / interpreter | 2.49 | 2.37–2.57 | 0.21 | 0.16 | 2.46 | 0.17 | 6.9% |
| `startup-hello` | lnako / compile | 61.63 | 60.62–61.85 | 1.24 | 0.45 | 61.11 | 1.07 | 1.8% |
| `startup-hello` | lnako / aot_run | 1.79 | 1.78–1.84 | 0.07 | 0.01 | 1.82 | 0.06 | 3.3% |
| `integer-arithmetic` | cnako / run | 129.87 | 129.44–130.54 | 1.10 | 0.86 | 130.03 | 0.91 | 0.7% |
| `integer-arithmetic` | gonako / run | 133.42 | 132.98–133.48 | 0.50 | 0.11 | 133.17 | 0.44 | 0.3% |
| `integer-arithmetic` | c / compile | 45.37 | 45.13–45.56 | 0.43 | 0.39 | 45.34 | 0.35 | 0.8% |
| `integer-arithmetic` | c / run | 2.23 | 2.20–2.25 | 0.05 | 0.04 | 2.23 | 0.04 | 1.8% |
| `integer-arithmetic` | rust / compile | 143.08 | 142.71–143.41 | 0.71 | 0.68 | 143.06 | 0.58 | 0.4% |
| `integer-arithmetic` | rust / run | 2.36 | 2.35–2.36 | 0.01 | 0.01 | 2.36 | 0.01 | 0.5% |
| `integer-arithmetic` | lnako / interpreter | 719.50 | 719.41–722.73 | 3.32 | 0.17 | 721.59 | 3.09 | 0.4% |
| `integer-arithmetic` | lnako / compile | 94.46 | 93.80–94.61 | 0.81 | 0.29 | 94.12 | 0.70 | 0.7% |
| `integer-arithmetic` | lnako / aot_run | 57.73 | 57.52–58.02 | 0.50 | 0.43 | 57.78 | 0.41 | 0.7% |
| `branch-mix` | cnako / run | 137.35 | 137.33–137.42 | 0.09 | 0.04 | 137.39 | 0.08 | 0.1% |
| `branch-mix` | gonako / run | 166.69 | 166.45–166.87 | 0.42 | 0.36 | 166.65 | 0.34 | 0.2% |
| `branch-mix` | lnako / interpreter | 1,018.01 | 1,015.08–1,022.72 | 7.65 | 5.86 | 1,019.20 | 6.30 | 0.6% |
| `branch-mix` | lnako / compile | 103.48 | 103.48–103.81 | 0.33 | 0.00 | 103.70 | 0.31 | 0.3% |
| `branch-mix` | lnako / aot_run | 75.35 | 75.33–75.65 | 0.32 | 0.04 | 75.53 | 0.29 | 0.4% |
| `function-call` | cnako / run | 169.74 | 169.24–170.25 | 1.01 | 1.00 | 169.75 | 0.83 | 0.5% |
| `function-call` | gonako / run | 116.86 | 116.30–117.64 | 1.34 | 1.12 | 117.01 | 1.10 | 0.9% |
| `function-call` | lnako / interpreter | 310.44 | 310.39–310.59 | 0.20 | 0.10 | 310.51 | 0.17 | 0.1% |
| `function-call` | lnako / compile | 89.30 | 88.82–89.43 | 0.60 | 0.26 | 89.07 | 0.52 | 0.6% |
| `function-call` | lnako / aot_run | 33.02 | 32.80–33.34 | 0.55 | 0.45 | 33.09 | 0.45 | 1.4% |
| `closure-call` | cnako / run | 153.65 | 152.41–155.22 | 2.81 | 2.48 | 153.87 | 2.30 | 1.5% |
| `closure-call` | gonako / run | 70.97 | 70.93–71.16 | 0.22 | 0.08 | 71.07 | 0.19 | 0.3% |
| `closure-call` | lnako / interpreter | 268.39 | 268.22–269.44 | 1.22 | 0.35 | 268.98 | 1.08 | 0.4% |
| `closure-call` | lnako / compile | 84.45 | 84.11–84.58 | 0.47 | 0.27 | 84.31 | 0.40 | 0.5% |
| `closure-call` | lnako / aot_run | 9.34 | 9.32–9.38 | 0.05 | 0.04 | 9.35 | 0.04 | 0.5% |
| `recursion` | cnako / run | 1,593.65 | 1,580.04–1,597.87 | 17.83 | 8.43 | 1,587.39 | 15.21 | 1.0% |
| `recursion` | gonako / run | 809.52 | 809.46–811.02 | 1.56 | 0.13 | 810.48 | 1.44 | 0.2% |
| `recursion` | lnako / interpreter | 729.96 | 727.44–730.68 | 3.24 | 1.45 | 728.76 | 2.78 | 0.4% |
| `recursion` | lnako / compile | 81.29 | 81.00–81.55 | 0.55 | 0.53 | 81.27 | 0.45 | 0.6% |
| `recursion` | lnako / aot_run | 222.11 | 221.76–224.40 | 2.64 | 0.69 | 223.41 | 2.35 | 1.0% |
| `nbody` | cnako / run | 158.66 | 157.51–160.69 | 3.17 | 2.30 | 159.25 | 2.62 | 1.6% |
| `nbody` | gonako / run | 47.09 | 46.84–47.18 | 0.34 | 0.17 | 46.98 | 0.29 | 0.6% |
| `nbody` | lnako / interpreter | 391.49 | 391.24–391.96 | 0.71 | 0.50 | 391.64 | 0.59 | 0.2% |
| `nbody` | lnako / compile | 207.09 | 206.86–207.76 | 0.89 | 0.45 | 207.38 | 0.76 | 0.4% |
| `nbody` | lnako / aot_run | 15.05 | 14.99–15.06 | 0.07 | 0.03 | 15.02 | 0.06 | 0.4% |
| `array-build` | cnako / run | 121.89 | 120.70–121.95 | 1.25 | 0.12 | 121.14 | 1.15 | 0.9% |
| `array-build` | gonako / run | 52.96 | 52.96–55.57 | 2.61 | 0.01 | 54.70 | 2.46 | 4.5% |
| `array-build` | lnako / interpreter | 232.65 | 232.46–233.63 | 1.17 | 0.38 | 233.18 | 1.02 | 0.4% |
| `array-build` | lnako / compile | 83.48 | 83.12–84.58 | 1.45 | 0.71 | 83.97 | 1.24 | 1.5% |
| `array-build` | lnako / aot_run | 6.00 | 5.98–6.02 | 0.04 | 0.03 | 5.99 | 0.03 | 0.6% |
| `array-scan` | cnako / run | 129.47 | 128.95–130.06 | 1.12 | 1.04 | 129.52 | 0.91 | 0.7% |
| `array-scan` | gonako / run | 108.07 | 107.95–110.53 | 2.58 | 0.24 | 109.63 | 2.38 | 2.2% |
| `array-scan` | lnako / interpreter | 696.29 | 693.97–699.40 | 5.44 | 4.64 | 696.82 | 4.46 | 0.6% |
| `array-scan` | lnako / compile | 98.39 | 97.45–98.43 | 0.99 | 0.08 | 97.79 | 0.91 | 0.9% |
| `array-scan` | lnako / aot_run | 26.62 | 26.58–26.79 | 0.21 | 0.07 | 26.71 | 0.18 | 0.7% |
| `hash-lookup` | cnako / run | 142.23 | 140.10–143.48 | 3.38 | 2.49 | 141.64 | 2.79 | 2.0% |
| `hash-lookup` | gonako / run | 72.51 | 72.02–72.86 | 0.85 | 0.70 | 72.42 | 0.69 | 1.0% |
| `hash-lookup` | lnako / interpreter | 481.68 | 478.36–481.90 | 3.53 | 0.43 | 479.61 | 3.23 | 0.7% |
| `hash-lookup` | lnako / compile | 104.16 | 104.02–104.19 | 0.17 | 0.05 | 104.08 | 0.15 | 0.1% |
| `hash-lookup` | lnako / aot_run | 50.36 | 50.19–50.65 | 0.46 | 0.33 | 50.44 | 0.38 | 0.8% |
| `string-concat` | cnako / run | 117.76 | 115.87–118.23 | 2.36 | 0.93 | 116.81 | 2.04 | 1.7% |
| `string-concat` | gonako / run | 22.75 | 22.63–22.88 | 0.25 | 0.25 | 22.75 | 0.21 | 0.9% |
| `string-concat` | c / compile | 43.96 | 43.49–44.13 | 0.65 | 0.35 | 43.76 | 0.55 | 1.2% |
| `string-concat` | c / run | 2.29 | 2.25–2.29 | 0.04 | 0.01 | 2.27 | 0.03 | 1.5% |
| `string-concat` | rust / compile | 133.95 | 133.91–134.09 | 0.18 | 0.08 | 134.01 | 0.15 | 0.1% |
| `string-concat` | rust / run | 2.44 | 2.41–2.46 | 0.06 | 0.05 | 2.43 | 0.05 | 1.9% |
| `string-concat` | lnako / interpreter | 56.51 | 56.42–56.56 | 0.15 | 0.10 | 56.48 | 0.12 | 0.2% |
| `string-concat` | lnako / compile | 79.19 | 79.03–79.23 | 0.20 | 0.08 | 79.11 | 0.18 | 0.2% |
| `string-concat` | lnako / aot_run | 28.21 | 28.20–28.27 | 0.07 | 0.02 | 28.24 | 0.06 | 0.2% |
| `string-builder` | cnako / run | 116.03 | 115.98–116.98 | 1.00 | 0.10 | 116.63 | 0.92 | 0.8% |
| `string-builder` | gonako / run | 21.93 | 21.67–22.73 | 1.05 | 0.52 | 22.29 | 0.90 | 4.0% |
| `string-builder` | c / compile | 43.91 | 43.90–44.02 | 0.12 | 0.02 | 43.97 | 0.11 | 0.2% |
| `string-builder` | c / run | 1.56 | 1.54–1.56 | 0.02 | 0.00 | 1.55 | 0.02 | 1.2% |
| `string-builder` | rust / compile | 132.08 | 132.04–132.34 | 0.30 | 0.08 | 132.23 | 0.27 | 0.2% |
| `string-builder` | rust / run | 1.73 | 1.72–1.76 | 0.04 | 0.03 | 1.74 | 0.03 | 1.9% |
| `string-builder` | lnako / interpreter | 66.10 | 65.83–66.13 | 0.31 | 0.07 | 65.94 | 0.28 | 0.4% |
| `string-builder` | lnako / compile | 92.12 | 91.75–92.32 | 0.57 | 0.41 | 92.01 | 0.47 | 0.5% |
| `string-builder` | lnako / aot_run | 3.99 | 3.97–4.01 | 0.04 | 0.03 | 3.99 | 0.04 | 0.9% |
| `unicode-scan` | cnako / run | 128.67 | 125.56–129.38 | 3.82 | 1.43 | 127.07 | 3.32 | 2.6% |
| `unicode-scan` | gonako / run | 58.46 | 58.31–58.64 | 0.33 | 0.30 | 58.48 | 0.27 | 0.5% |
| `unicode-scan` | lnako / interpreter | 337.20 | 336.49–338.06 | 1.57 | 1.42 | 337.30 | 1.28 | 0.4% |
| `unicode-scan` | lnako / compile | 110.16 | 110.07–110.62 | 0.55 | 0.18 | 110.40 | 0.48 | 0.4% |
| `unicode-scan` | lnako / aot_run | 29.53 | 29.49–29.57 | 0.08 | 0.07 | 29.53 | 0.06 | 0.2% |
| `sieve` | cnako / run | 129.57 | 128.84–133.38 | 4.54 | 1.45 | 131.63 | 3.98 | 3.0% |
| `sieve` | gonako / run | 39.86 | 39.74–40.54 | 0.80 | 0.25 | 40.23 | 0.71 | 1.8% |
| `sieve` | lnako / interpreter | 439.60 | 439.26–443.38 | 4.12 | 0.67 | 441.90 | 3.74 | 0.8% |
| `sieve` | lnako / compile | 112.67 | 112.66–113.16 | 0.50 | 0.03 | 112.99 | 0.46 | 0.4% |
| `sieve` | lnako / aot_run | 14.41 | 14.37–14.46 | 0.08 | 0.07 | 14.42 | 0.07 | 0.5% |
| `binary-trees` | cnako / run | 163.48 | 163.10–163.63 | 0.53 | 0.30 | 163.33 | 0.44 | 0.3% |
| `binary-trees` | gonako / run | 51.74 | 51.50–51.90 | 0.40 | 0.32 | 51.69 | 0.33 | 0.6% |
| `binary-trees` | lnako / interpreter | 48.76 | 48.51–48.83 | 0.32 | 0.13 | 48.64 | 0.28 | 0.6% |
| `binary-trees` | lnako / compile | 119.06 | 118.87–119.48 | 0.61 | 0.38 | 119.21 | 0.51 | 0.4% |
| `binary-trees` | lnako / aot_run | 17.20 | 17.17–17.29 | 0.13 | 0.06 | 17.24 | 0.11 | 0.6% |
| `word-count` | cnako / run | 125.37 | 125.18–125.48 | 0.30 | 0.22 | 125.32 | 0.25 | 0.2% |
| `word-count` | gonako / run | 37.12 | 37.05–38.91 | 1.85 | 0.12 | 38.27 | 1.72 | 4.5% |
| `word-count` | lnako / interpreter | 251.92 | 251.65–252.72 | 1.07 | 0.54 | 252.27 | 0.91 | 0.4% |
| `word-count` | lnako / compile | 132.19 | 131.95–132.89 | 0.95 | 0.49 | 132.49 | 0.80 | 0.6% |
| `word-count` | lnako / aot_run | 15.20 | 15.17–15.30 | 0.13 | 0.06 | 15.24 | 0.11 | 0.7% |
| `json-transform` | cnako / run | 128.48 | 128.42–133.96 | 5.54 | 0.13 | 132.09 | 5.20 | 3.9% |
| `json-transform` | gonako / run | 22.97 | 22.37–23.55 | 1.18 | 1.14 | 22.95 | 0.96 | 4.2% |
| `json-transform` | lnako / interpreter | 67.21 | 67.11–67.37 | 0.26 | 0.20 | 67.25 | 0.22 | 0.3% |
| `json-transform` | lnako / compile | 136.22 | 136.18–136.26 | 0.07 | 0.07 | 136.22 | 0.06 | 0.0% |
| `json-transform` | lnako / aot_run | 7.12 | 7.08–7.13 | 0.05 | 0.01 | 7.10 | 0.05 | 0.7% |
| `file-read` | cnako / run | 118.63 | 117.89–118.71 | 0.82 | 0.16 | 118.19 | 0.74 | 0.6% |
| `file-read` | gonako / run | 8.47 | 8.42–8.60 | 0.17 | 0.10 | 8.52 | 0.15 | 1.7% |
| `file-read` | lnako / interpreter | 6.79 | 6.76–6.83 | 0.07 | 0.07 | 6.79 | 0.06 | 0.9% |
| `file-read` | lnako / compile | 108.28 | 107.72–109.04 | 1.32 | 1.13 | 108.41 | 1.08 | 1.0% |
| `file-read` | lnako / aot_run | 2.09 | 2.07–2.11 | 0.04 | 0.03 | 2.09 | 0.03 | 1.6% |

19ケース・107測定行で期待出力を確認済みです。共有CI・OS・CPUやページキャッシュの影響があるため、環境間の直接順位付けや総合スコアには使用しません。
