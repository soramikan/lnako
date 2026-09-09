# ベンチマーク結果 — macos / aarch64

[概要と読み方](RESULTS.md) · [元のJSON](2026-09-09-rc-macos-arm64-comparison.json)

## 測定条件

| 項目 | 値 |
| --- | --- |
| 測定日時（UTC） | 2026-09-08T15:46:34.825Z |
| 測定コミット | 5dcf585f4db394206fb5480ef6b184d3138c6daf（clean） |
| プロファイル | smoke / warmup 1回 / 測定 3回 |
| AOT / C / Rust 最適化 | O2 |
| CPU | Apple M1 (Virtual) |
| 論理CPU数 | 3 |
| メモリ | 7.00 GiB |
| OS release | 24.6.0 |
| スイートSHA-256 | 174b77cf2bffd4eb0357ac0471bc0cb9dff2fe70f4e6cbe9c6365914787e8e21 |

### 処理系とコンパイラ

| 処理系 | 区分 | 自己表示バージョン |
| --- | --- | --- |
| lnako | 正式比較 | lnako 0.1.0 |
| cnako | 正式比較 | v3.7.24 |
| gonako | 正式比較 | gonako v3.6.0 (darwin/arm64) |
| c | 参考値 | clang version 22.1.8 (https://github.com/llvm/llvm-project ca7933e47d3a3451d81e72ac174dcb5aa28b59d1) |
| rust | 参考値 | rustc 1.98.0 (88d9e12ae 2026-08-18) |

gonako配布版: 3.8.1。配布版とバイナリの自己表示バージョンは別々に記録しています。SHA-256: `dd6218bcb28e3406356b051350530c1082fae62b70399e429fed9de0f6ab9c27`。
[公式配布元](https://github.com/kujirahand/nadesiko3go/releases/download/3.8.1/gonako-3.8.1-darwin-arm64)

## 正式比較：実行時間の中央値

単位は **ms**、小さいほど短時間です。全値にプロセス起動・終了を含み、lnako AOTの事前コンパイルは含みません。† はsteady_stateで中央値200ms未満の測定です。— は未測定・未対応で、0msではありません。

| ケース | cnako | gonako | lnako interpreter | lnako AOT |
| --- | ---: | ---: | ---: | ---: |
| `startup-empty` | 172.09 | 41.60 | 8.10 | 3.37 |
| `startup-hello` | 150.76 | 24.16 | 9.27 | 3.26 |
| `integer-arithmetic` | 157.46 † | 110.97 † | 754.98 | 33.02 † |
| `branch-mix` | 174.50 † | 134.65 † | 1,010.81 | 51.12 † |
| `function-call` | 177.87 † | 98.51 † | 323.01 | 14.79 † |
| `closure-call` | 171.94 † | 49.66 † | 250.48 | 5.72 † |
| `recursion` | 2,088.47 | 725.36 | 598.92 | 101.28 † |
| `nbody` | 136.89 † | 38.48 † | 380.14 | 8.98 † |
| `array-build` | 127.84 † | 44.92 † | 192.88 † | 7.64 † |
| `array-scan` | 186.44 † | 103.50 † | 745.63 | 13.77 † |
| `hash-lookup` | 159.76 † | 56.57 † | 454.26 | 58.93 † |
| `string-concat` | 128.89 † | 27.94 † | 35.18 † | 68.31 † |
| `string-builder` | 121.68 † | 19.35 † | 46.39 † | 4.79 † |
| `unicode-scan` | 106.76 † | 47.09 † | 327.19 | 43.80 † |
| `sieve` | 128.93 † | 37.12 † | 417.70 | 7.34 † |
| `binary-trees` | 114.32 † | 37.47 † | 30.74 † | 12.68 † |
| `word-count` | 94.18 † | 28.84 † | 197.07 † | 17.42 † |
| `json-transform` | 112.31 † | 26.36 † | 60.86 † | 9.10 † |
| `file-read` | 96.25 † | 13.24 † | 5.80 † | 3.06 † |

## 参考値：C・Rustの実行時間

同じ入力・反復数・期待出力に揃えた別言語の実装です。処理系の正式比較とは区別します。単位はmsで、事前コンパイルを含みません。文字列の反復コピーと可変構築は別のケースとして扱います。

| ケース | C | Rust |
| --- | ---: | ---: |
| `integer-arithmetic` | 2.97 † | 6.11 † |
| `string-concat` | 4.34 † | 4.21 † |
| `string-builder` | 1.49 † | 2.62 † |

## コンパイル時間と実行ファイルサイズ

時間はms、サイズはbytesです。cnako・gonakoのソース実行と、lnako・C・Rustの実行ファイル生成を同一のコンパイル測定として扱いません。

| ケース | 処理系 | 中央値 | P25–P75 | 実行ファイル（bytes） |
| --- | --- | ---: | ---: | ---: |
| `startup-empty` | lnako | 200.01 | 197.65–200.46 | 337,568 |
| `startup-hello` | lnako | 207.74 | 193.68–224.51 | 338,032 |
| `integer-arithmetic` | c | 121.01 | 119.51–125.29 | 33,480 |
| `integer-arithmetic` | rust | 281.03 | 271.91–293.54 | 489,048 |
| `integer-arithmetic` | lnako | 207.96 | 196.66–280.58 | 504,464 |
| `branch-mix` | lnako | 145.59 | 144.76–153.09 | 554,192 |
| `function-call` | lnako | 137.34 | 135.93–141.43 | 504,592 |
| `closure-call` | lnako | 140.75 | 135.66–149.84 | 421,664 |
| `recursion` | lnako | 144.64 | 139.19–159.13 | 553,920 |
| `nbody` | lnako | 247.74 | 231.45–249.77 | 571,168 |
| `array-build` | lnako | 140.64 | 139.75–155.85 | 504,544 |
| `array-scan` | lnako | 139.80 | 137.52–153.01 | 504,640 |
| `hash-lookup` | lnako | 210.41 | 195.59–238.44 | 521,280 |
| `string-concat` | c | 127.96 | 125.30–137.17 | 33,608 |
| `string-concat` | rust | 212.85 | 199.04–247.62 | 488,632 |
| `string-concat` | lnako | 122.76 | 120.26–130.21 | 504,576 |
| `string-builder` | c | 116.91 | 104.16–117.88 | 33,608 |
| `string-builder` | rust | 245.29 | 210.65–254.06 | 488,632 |
| `string-builder` | lnako | 147.64 | 144.27–151.75 | 7,609,632 |
| `unicode-scan` | lnako | 197.00 | 188.46–204.15 | 7,609,648 |
| `sieve` | lnako | 145.73 | 137.96–147.87 | 554,224 |
| `binary-trees` | lnako | 133.17 | 133.13–136.46 | 554,640 |
| `word-count` | lnako | 153.93 | 152.46–158.47 | 7,609,824 |
| `json-transform` | lnako | 183.60 | 180.01–193.09 | 7,609,728 |
| `file-read` | lnako | 158.97 | 148.24–161.78 | 7,609,472 |

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
| `startup-empty` | cnako / run | 172.09 | 171.01–172.14 | 1.12 | 0.10 | 171.40 | 1.04 | 0.6% |
| `startup-empty` | gonako / run | 41.60 | 39.85–47.06 | 7.21 | 3.50 | 44.08 | 6.14 | 13.9% |
| `startup-empty` | lnako / interpreter | 8.10 | 6.78–9.53 | 2.75 | 2.64 | 8.17 | 2.25 | 27.5% |
| `startup-empty` | lnako / compile | 200.01 | 197.65–200.46 | 2.81 | 0.90 | 198.74 | 2.46 | 1.2% |
| `startup-empty` | lnako / aot_run | 3.37 | 3.37–3.43 | 0.06 | 0.01 | 3.41 | 0.05 | 1.6% |
| `startup-hello` | cnako / run | 150.76 | 142.30–158.00 | 15.69 | 14.47 | 149.95 | 12.82 | 8.6% |
| `startup-hello` | gonako / run | 24.16 | 22.60–27.37 | 4.78 | 3.12 | 25.26 | 3.98 | 15.7% |
| `startup-hello` | lnako / interpreter | 9.27 | 7.07–11.90 | 4.83 | 4.39 | 9.56 | 3.95 | 41.3% |
| `startup-hello` | lnako / compile | 207.74 | 193.68–224.51 | 30.82 | 28.12 | 209.54 | 25.20 | 12.0% |
| `startup-hello` | lnako / aot_run | 3.26 | 3.12–4.65 | 1.53 | 0.27 | 4.10 | 1.38 | 33.7% |
| `integer-arithmetic` | cnako / run | 157.46 | 155.63–179.36 | 23.74 | 3.66 | 170.84 | 21.57 | 12.6% |
| `integer-arithmetic` | gonako / run | 110.97 | 105.66–115.12 | 9.45 | 8.28 | 110.19 | 7.74 | 7.0% |
| `integer-arithmetic` | c / compile | 121.01 | 119.51–125.29 | 5.78 | 3.01 | 122.86 | 4.90 | 4.0% |
| `integer-arithmetic` | c / run | 2.97 | 2.93–3.06 | 0.12 | 0.07 | 3.01 | 0.10 | 3.5% |
| `integer-arithmetic` | rust / compile | 281.03 | 271.91–293.54 | 21.63 | 18.23 | 283.29 | 17.73 | 6.3% |
| `integer-arithmetic` | rust / run | 6.11 | 5.39–6.43 | 1.04 | 0.64 | 5.84 | 0.87 | 14.8% |
| `integer-arithmetic` | lnako / interpreter | 754.98 | 745.31–757.07 | 11.76 | 4.18 | 749.93 | 10.24 | 1.4% |
| `integer-arithmetic` | lnako / compile | 207.96 | 196.66–280.58 | 83.92 | 22.60 | 248.84 | 74.37 | 29.9% |
| `integer-arithmetic` | lnako / aot_run | 33.02 | 31.89–37.07 | 5.17 | 2.26 | 34.97 | 4.44 | 12.7% |
| `branch-mix` | cnako / run | 174.50 | 168.28–177.87 | 9.59 | 6.75 | 172.60 | 7.94 | 4.6% |
| `branch-mix` | gonako / run | 134.65 | 132.48–137.88 | 5.40 | 4.35 | 135.35 | 4.44 | 3.3% |
| `branch-mix` | lnako / interpreter | 1,010.81 | 995.06–1,028.65 | 33.59 | 31.48 | 1,012.21 | 27.44 | 2.7% |
| `branch-mix` | lnako / compile | 145.59 | 144.76–153.09 | 8.34 | 1.66 | 150.04 | 7.50 | 5.0% |
| `branch-mix` | lnako / aot_run | 51.12 | 47.92–55.33 | 7.41 | 6.39 | 51.79 | 6.07 | 11.7% |
| `function-call` | cnako / run | 177.87 | 173.02–177.88 | 4.86 | 0.01 | 174.64 | 4.58 | 2.6% |
| `function-call` | gonako / run | 98.51 | 95.63–99.51 | 3.88 | 2.00 | 97.25 | 3.29 | 3.4% |
| `function-call` | lnako / interpreter | 323.01 | 309.23–327.59 | 18.37 | 9.16 | 316.88 | 15.61 | 4.9% |
| `function-call` | lnako / compile | 137.34 | 135.93–141.43 | 5.50 | 2.82 | 139.13 | 4.66 | 3.4% |
| `function-call` | lnako / aot_run | 14.79 | 14.62–15.10 | 0.48 | 0.34 | 14.88 | 0.40 | 2.7% |
| `closure-call` | cnako / run | 171.94 | 164.10–172.00 | 7.90 | 0.13 | 166.75 | 7.42 | 4.5% |
| `closure-call` | gonako / run | 49.66 | 49.33–51.16 | 1.83 | 0.65 | 50.44 | 1.60 | 3.2% |
| `closure-call` | lnako / interpreter | 250.48 | 245.73–265.67 | 19.95 | 9.51 | 257.44 | 17.01 | 6.6% |
| `closure-call` | lnako / compile | 140.75 | 135.66–149.84 | 14.18 | 10.17 | 143.42 | 11.73 | 8.2% |
| `closure-call` | lnako / aot_run | 5.72 | 5.71–5.72 | 0.01 | 0.01 | 5.72 | 0.01 | 0.2% |
| `recursion` | cnako / run | 2,088.47 | 2,038.07–2,170.83 | 132.76 | 100.80 | 2,109.77 | 109.44 | 5.2% |
| `recursion` | gonako / run | 725.36 | 698.96–735.29 | 36.33 | 19.84 | 714.38 | 30.66 | 4.3% |
| `recursion` | lnako / interpreter | 598.92 | 574.23–619.24 | 45.01 | 40.64 | 596.00 | 36.81 | 6.2% |
| `recursion` | lnako / compile | 144.64 | 139.19–159.13 | 19.93 | 10.90 | 150.67 | 16.82 | 11.2% |
| `recursion` | lnako / aot_run | 101.28 | 98.91–103.75 | 4.84 | 4.74 | 101.35 | 3.95 | 3.9% |
| `nbody` | cnako / run | 136.89 | 133.61–144.10 | 10.49 | 6.56 | 139.51 | 8.77 | 6.3% |
| `nbody` | gonako / run | 38.48 | 35.53–39.09 | 3.56 | 1.23 | 36.92 | 3.11 | 8.4% |
| `nbody` | lnako / interpreter | 380.14 | 351.94–380.66 | 28.71 | 1.04 | 361.69 | 26.83 | 7.4% |
| `nbody` | lnako / compile | 247.74 | 231.45–249.77 | 18.32 | 4.07 | 238.24 | 16.40 | 6.9% |
| `nbody` | lnako / aot_run | 8.98 | 8.89–9.00 | 0.10 | 0.04 | 8.93 | 0.09 | 1.0% |
| `array-build` | cnako / run | 127.84 | 126.58–130.79 | 4.21 | 2.52 | 128.96 | 3.53 | 2.7% |
| `array-build` | gonako / run | 44.92 | 41.81–46.96 | 5.15 | 4.09 | 44.21 | 4.23 | 9.6% |
| `array-build` | lnako / interpreter | 192.88 | 190.88–197.72 | 6.84 | 4.01 | 194.77 | 5.74 | 2.9% |
| `array-build` | lnako / compile | 140.64 | 139.75–155.85 | 16.09 | 1.77 | 150.19 | 14.77 | 9.8% |
| `array-build` | lnako / aot_run | 7.64 | 7.20–7.82 | 0.62 | 0.37 | 7.47 | 0.52 | 7.0% |
| `array-scan` | cnako / run | 186.44 | 167.50–192.68 | 25.18 | 12.48 | 177.97 | 21.41 | 12.0% |
| `array-scan` | gonako / run | 103.50 | 99.66–103.80 | 4.14 | 0.60 | 101.14 | 3.77 | 3.7% |
| `array-scan` | lnako / interpreter | 745.63 | 685.77–753.48 | 67.72 | 15.70 | 710.96 | 60.48 | 8.5% |
| `array-scan` | lnako / compile | 139.80 | 137.52–153.01 | 15.49 | 4.55 | 147.09 | 13.65 | 9.3% |
| `array-scan` | lnako / aot_run | 13.77 | 13.73–13.88 | 0.15 | 0.09 | 13.81 | 0.12 | 0.9% |
| `hash-lookup` | cnako / run | 159.76 | 157.14–161.39 | 4.25 | 3.27 | 159.10 | 3.50 | 2.2% |
| `hash-lookup` | gonako / run | 56.57 | 56.00–67.64 | 11.63 | 1.13 | 63.57 | 10.71 | 16.9% |
| `hash-lookup` | lnako / interpreter | 454.26 | 453.93–460.73 | 6.80 | 0.66 | 458.35 | 6.27 | 1.4% |
| `hash-lookup` | lnako / compile | 210.41 | 195.59–238.44 | 42.85 | 29.64 | 219.22 | 35.53 | 16.2% |
| `hash-lookup` | lnako / aot_run | 58.93 | 58.33–59.38 | 1.05 | 0.90 | 58.83 | 0.86 | 1.5% |
| `string-concat` | cnako / run | 128.89 | 119.92–135.33 | 15.41 | 12.88 | 127.20 | 12.64 | 9.9% |
| `string-concat` | gonako / run | 27.94 | 25.12–28.42 | 3.29 | 0.94 | 26.38 | 2.91 | 11.0% |
| `string-concat` | c / compile | 127.96 | 125.30–137.17 | 11.87 | 5.32 | 132.33 | 10.17 | 7.7% |
| `string-concat` | c / run | 4.34 | 3.65–5.80 | 2.14 | 1.36 | 4.86 | 1.79 | 36.8% |
| `string-concat` | rust / compile | 212.85 | 199.04–247.62 | 48.57 | 27.61 | 226.82 | 40.87 | 18.0% |
| `string-concat` | rust / run | 4.21 | 3.88–5.43 | 1.55 | 0.66 | 4.80 | 1.34 | 27.8% |
| `string-concat` | lnako / interpreter | 35.18 | 33.58–37.18 | 3.60 | 3.20 | 35.44 | 2.95 | 8.3% |
| `string-concat` | lnako / compile | 122.76 | 120.26–130.21 | 9.96 | 5.01 | 126.06 | 8.46 | 6.7% |
| `string-concat` | lnako / aot_run | 68.31 | 64.79–69.56 | 4.77 | 2.49 | 66.79 | 4.04 | 6.1% |
| `string-builder` | cnako / run | 121.68 | 112.46–129.06 | 16.60 | 14.76 | 120.45 | 13.58 | 11.3% |
| `string-builder` | gonako / run | 19.35 | 19.01–21.38 | 2.37 | 0.68 | 20.48 | 2.09 | 10.2% |
| `string-builder` | c / compile | 116.91 | 104.16–117.88 | 13.72 | 1.95 | 109.06 | 12.50 | 11.5% |
| `string-builder` | c / run | 1.49 | 1.47–1.53 | 0.06 | 0.02 | 1.51 | 0.05 | 3.3% |
| `string-builder` | rust / compile | 245.29 | 210.65–254.06 | 43.40 | 17.53 | 228.04 | 37.48 | 16.4% |
| `string-builder` | rust / run | 2.62 | 2.51–3.63 | 1.12 | 0.23 | 3.22 | 1.00 | 31.2% |
| `string-builder` | lnako / interpreter | 46.39 | 45.74–49.09 | 3.35 | 1.31 | 47.75 | 2.90 | 6.1% |
| `string-builder` | lnako / compile | 147.64 | 144.27–151.75 | 7.48 | 6.73 | 148.13 | 6.11 | 4.1% |
| `string-builder` | lnako / aot_run | 4.79 | 4.78–4.80 | 0.02 | 0.01 | 4.79 | 0.01 | 0.3% |
| `unicode-scan` | cnako / run | 106.76 | 103.85–111.05 | 7.20 | 5.83 | 107.67 | 5.91 | 5.5% |
| `unicode-scan` | gonako / run | 47.09 | 44.89–48.04 | 3.15 | 1.89 | 46.26 | 2.64 | 5.7% |
| `unicode-scan` | lnako / interpreter | 327.19 | 317.48–344.20 | 26.72 | 19.42 | 332.05 | 22.09 | 6.7% |
| `unicode-scan` | lnako / compile | 197.00 | 188.46–204.15 | 15.69 | 14.30 | 196.07 | 12.83 | 6.5% |
| `unicode-scan` | lnako / aot_run | 43.80 | 43.67–46.71 | 3.04 | 0.27 | 45.65 | 2.81 | 6.1% |
| `sieve` | cnako / run | 128.93 | 127.40–142.77 | 15.37 | 3.07 | 137.13 | 13.82 | 10.1% |
| `sieve` | gonako / run | 37.12 | 35.35–37.93 | 2.58 | 1.62 | 36.48 | 2.16 | 5.9% |
| `sieve` | lnako / interpreter | 417.70 | 373.37–419.74 | 46.37 | 4.08 | 389.51 | 42.79 | 11.0% |
| `sieve` | lnako / compile | 145.73 | 137.96–147.87 | 9.91 | 4.28 | 141.97 | 8.51 | 6.0% |
| `sieve` | lnako / aot_run | 7.34 | 7.25–7.57 | 0.32 | 0.18 | 7.43 | 0.27 | 3.6% |
| `binary-trees` | cnako / run | 114.32 | 113.99–115.52 | 1.53 | 0.67 | 114.90 | 1.32 | 1.1% |
| `binary-trees` | gonako / run | 37.47 | 37.14–38.13 | 0.99 | 0.68 | 37.68 | 0.82 | 2.2% |
| `binary-trees` | lnako / interpreter | 30.74 | 30.62–30.90 | 0.29 | 0.24 | 30.77 | 0.23 | 0.8% |
| `binary-trees` | lnako / compile | 133.17 | 133.13–136.46 | 3.34 | 0.10 | 135.33 | 3.12 | 2.3% |
| `binary-trees` | lnako / aot_run | 12.68 | 12.63–13.11 | 0.48 | 0.10 | 12.93 | 0.43 | 3.3% |
| `word-count` | cnako / run | 94.18 | 93.47–95.46 | 1.98 | 1.42 | 94.56 | 1.64 | 1.7% |
| `word-count` | gonako / run | 28.84 | 28.71–29.34 | 0.63 | 0.26 | 29.09 | 0.54 | 1.9% |
| `word-count` | lnako / interpreter | 197.07 | 192.95–198.80 | 5.84 | 3.45 | 195.48 | 4.90 | 2.5% |
| `word-count` | lnako / compile | 153.93 | 152.46–158.47 | 6.00 | 2.93 | 155.98 | 5.11 | 3.3% |
| `word-count` | lnako / aot_run | 17.42 | 17.12–18.03 | 0.91 | 0.59 | 17.63 | 0.76 | 4.3% |
| `json-transform` | cnako / run | 112.31 | 108.00–121.70 | 13.70 | 8.62 | 115.70 | 11.44 | 9.9% |
| `json-transform` | gonako / run | 26.36 | 25.86–26.59 | 0.73 | 0.47 | 26.18 | 0.61 | 2.3% |
| `json-transform` | lnako / interpreter | 60.86 | 60.74–60.87 | 0.13 | 0.03 | 60.78 | 0.12 | 0.2% |
| `json-transform` | lnako / compile | 183.60 | 180.01–193.09 | 13.08 | 7.17 | 187.54 | 11.04 | 5.9% |
| `json-transform` | lnako / aot_run | 9.10 | 8.91–9.21 | 0.30 | 0.22 | 9.05 | 0.25 | 2.8% |
| `file-read` | cnako / run | 96.25 | 89.42–97.59 | 8.17 | 2.68 | 92.59 | 7.16 | 7.7% |
| `file-read` | gonako / run | 13.24 | 13.16–13.48 | 0.33 | 0.17 | 13.35 | 0.28 | 2.1% |
| `file-read` | lnako / interpreter | 5.80 | 5.75–5.99 | 0.23 | 0.09 | 5.89 | 0.20 | 3.4% |
| `file-read` | lnako / compile | 158.97 | 148.24–161.78 | 13.54 | 5.60 | 153.68 | 11.67 | 7.6% |
| `file-read` | lnako / aot_run | 3.06 | 3.00–3.12 | 0.12 | 0.11 | 3.06 | 0.10 | 3.1% |

19ケース・107測定行で期待出力を確認済みです。共有CI・OS・CPUやページキャッシュの影響があるため、環境間の直接順位付けや総合スコアには使用しません。
