# ベンチマーク結果 — macOS arm64（ローカル）

[概要と読み方](RESULTS.md) · [元のJSON](2026-09-06-macos-local.json)

開発機Apple M1での測定です。CIの測定と混同せず、同じ表内の処理系同士で比較してください。lnakoはReleaseSafe、LLVM/LLDは22.1.8、Node.jsは24.15.0を使用しています。

## 測定条件

| 項目 | 値 |
| --- | --- |
| 測定日時（UTC） | 2026-09-05T23:37:26.652Z |
| 測定コミット | d072a540a26765bd16b5b61d767c5728eef7c3dd（clean） |
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
| `startup-empty` | 76.01 | 13.03 | 3.07 | 2.85 |
| `startup-hello` | 83.72 | 13.36 | 3.18 | 3.03 |
| `integer-arithmetic` | 104.50 † | 76.55 † | 599.93 | 29.01 † |
| `branch-mix` | 112.76 † | 101.55 † | 853.86 | 43.17 † |
| `function-call` | 117.69 † | 58.10 † | 256.43 | 17.28 † |
| `closure-call` | 110.41 † | 39.68 † | 228.78 | 8.01 † |
| `recursion` | 1,308.26 | 379.00 | 604.95 | 225.32 |
| `nbody` | 107.60 † | 28.85 † | 320.39 | 19.81 † |
| `array-build` | 88.16 † | 31.09 † | 160.95 † | 11.71 † |
| `array-scan` | 93.65 † | 53.91 † | 561.11 | 28.85 † |
| `hash-lookup` | 100.11 † | 42.33 † | 409.42 | 2,622.63 |
| `string-concat` | 83.44 † | 20.80 † | 28.84 † | 101.62 † |
| `string-builder` | 86.28 † | 18.93 † | 45.65 † | 8.60 † |
| `unicode-scan` | 93.84 † | 33.68 † | 279.19 | 33.00 † |
| `sieve` | 99.81 † | 27.08 † | 369.53 | 18.29 † |
| `binary-trees` | 110.98 † | 35.20 † | 35.30 † | 23.88 † |
| `word-count` | 91.85 † | 25.77 † | 208.25 | 15.13 † |
| `json-transform` | 90.02 † | 19.92 † | 54.68 † | 8.06 † |
| `file-read` | 83.78 † | 13.73 † | 7.08 † | 3.10 † |

## 参考値：C・Rustの実行時間

同じ入力・反復数・期待出力に揃えた別言語の実装です。処理系の正式比較とは区別します。単位はmsで、事前コンパイルを含みません。文字列の反復コピーと可変構築は別のケースとして扱います。

| ケース | C | Rust |
| --- | ---: | ---: |
| `integer-arithmetic` | 2.61 † | 3.19 † |
| `string-concat` | 2.94 † | 3.18 † |
| `string-builder` | 2.31 † | 2.40 † |

## コンパイル時間と実行ファイルサイズ

時間はms、サイズはbytesです。cnako・gonakoのソース実行と、lnako・C・Rustの実行ファイル生成を同一のコンパイル測定として扱いません。

| ケース | 処理系 | 中央値 | P25–P75 | 実行ファイル（bytes） |
| --- | --- | ---: | ---: | ---: |
| `startup-empty` | lnako | 104.12 | 103.53–105.44 | 8,354,016 |
| `startup-hello` | lnako | 106.65 | 106.14–106.85 | 8,354,064 |
| `integer-arithmetic` | c | 84.47 | 84.02–87.64 | 33,480 |
| `integer-arithmetic` | rust | 173.43 | 172.50–173.77 | 469,096 |
| `integer-arithmetic` | lnako | 127.93 | 126.86–129.09 | 8,354,384 |
| `branch-mix` | lnako | 145.20 | 144.02–146.74 | 8,354,416 |
| `function-call` | lnako | 129.85 | 127.30–132.06 | 8,354,432 |
| `closure-call` | lnako | 122.04 | 121.48–122.57 | 8,354,400 |
| `recursion` | lnako | 121.31 | 119.81–122.68 | 8,354,352 |
| `nbody` | lnako | 239.15 | 237.97–242.12 | 8,371,248 |
| `array-build` | lnako | 124.09 | 122.21–124.32 | 8,354,320 |
| `array-scan` | lnako | 132.11 | 129.96–134.51 | 8,354,416 |
| `hash-lookup` | lnako | 131.73 | 131.15–132.44 | 8,354,416 |
| `string-concat` | c | 85.34 | 84.48–87.04 | 33,608 |
| `string-concat` | rust | 168.58 | 167.00–168.91 | 468,664 |
| `string-concat` | lnako | 119.13 | 118.78–120.16 | 8,354,272 |
| `string-builder` | c | 84.59 | 83.73–84.78 | 33,608 |
| `string-builder` | rust | 172.04 | 166.83–174.77 | 468,664 |
| `string-builder` | lnako | 120.22 | 119.31–120.64 | 8,354,320 |
| `unicode-scan` | lnako | 132.25 | 131.58–133.12 | 8,354,464 |
| `sieve` | lnako | 152.12 | 151.07–152.69 | 8,354,448 |
| `binary-trees` | lnako | 145.27 | 143.85–145.48 | 8,354,608 |
| `word-count` | lnako | 151.29 | 150.03–152.06 | 8,354,464 |
| `json-transform` | lnako | 159.84 | 158.42–166.60 | 8,354,608 |
| `file-read` | lnako | 135.21 | 133.82–137.65 | 8,354,448 |
| `compile-stress-medium` | lnako | 664.91 | 654.28–672.58 | 8,387,424 |

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
| `startup-empty` | cnako / run | 76.01 | 75.00–76.66 | 1.67 | 0.91 | 76.20 | 1.81 | 2.4% |
| `startup-empty` | gonako / run | 13.03 | 12.92–13.14 | 0.21 | 0.11 | 13.00 | 0.26 | 2.0% |
| `startup-empty` | lnako / interpreter | 3.07 | 2.82–3.22 | 0.40 | 0.18 | 3.03 | 0.24 | 8.0% |
| `startup-empty` | lnako / compile | 104.12 | 103.53–105.44 | 1.91 | 0.93 | 104.44 | 1.46 | 1.4% |
| `startup-empty` | lnako / aot_run | 2.85 | 2.77–2.96 | 0.19 | 0.11 | 2.88 | 0.19 | 6.5% |
| `startup-hello` | cnako / run | 83.72 | 81.43–88.20 | 6.78 | 2.87 | 84.83 | 4.97 | 5.9% |
| `startup-hello` | gonako / run | 13.36 | 13.08–13.47 | 0.39 | 0.19 | 13.30 | 0.23 | 1.7% |
| `startup-hello` | lnako / interpreter | 3.18 | 3.04–3.28 | 0.25 | 0.14 | 3.18 | 0.22 | 7.0% |
| `startup-hello` | lnako / compile | 106.65 | 106.14–106.85 | 0.71 | 0.45 | 106.60 | 0.66 | 0.6% |
| `startup-hello` | lnako / aot_run | 3.03 | 2.74–3.31 | 0.57 | 0.30 | 3.06 | 0.38 | 12.4% |
| `integer-arithmetic` | cnako / run | 104.50 | 103.43–105.14 | 1.71 | 1.00 | 105.06 | 3.03 | 2.9% |
| `integer-arithmetic` | gonako / run | 76.55 | 76.29–77.48 | 1.19 | 0.49 | 76.77 | 0.67 | 0.9% |
| `integer-arithmetic` | c / compile | 84.47 | 84.02–87.64 | 3.62 | 1.06 | 85.53 | 2.13 | 2.5% |
| `integer-arithmetic` | c / run | 2.61 | 2.45–2.88 | 0.43 | 0.19 | 2.66 | 0.22 | 8.3% |
| `integer-arithmetic` | rust / compile | 173.43 | 172.50–173.77 | 1.27 | 0.76 | 174.45 | 3.38 | 1.9% |
| `integer-arithmetic` | rust / run | 3.19 | 3.03–3.32 | 0.29 | 0.15 | 3.20 | 0.22 | 6.9% |
| `integer-arithmetic` | lnako / interpreter | 599.93 | 599.36–602.64 | 3.27 | 1.17 | 601.09 | 2.37 | 0.4% |
| `integer-arithmetic` | lnako / compile | 127.93 | 126.86–129.09 | 2.23 | 1.29 | 128.12 | 1.90 | 1.5% |
| `integer-arithmetic` | lnako / aot_run | 29.01 | 28.94–29.10 | 0.16 | 0.09 | 29.01 | 0.10 | 0.3% |
| `branch-mix` | cnako / run | 112.76 | 111.21–113.79 | 2.58 | 1.37 | 112.63 | 2.08 | 1.8% |
| `branch-mix` | gonako / run | 101.55 | 101.40–102.12 | 0.72 | 0.22 | 101.77 | 0.46 | 0.4% |
| `branch-mix` | lnako / interpreter | 853.86 | 851.21–855.14 | 3.93 | 2.59 | 853.69 | 2.75 | 0.3% |
| `branch-mix` | lnako / compile | 145.20 | 144.02–146.74 | 2.72 | 1.64 | 146.10 | 4.08 | 2.8% |
| `branch-mix` | lnako / aot_run | 43.17 | 42.50–43.49 | 0.99 | 0.66 | 43.09 | 0.56 | 1.3% |
| `function-call` | cnako / run | 117.69 | 117.48–118.27 | 0.79 | 0.56 | 118.06 | 1.28 | 1.1% |
| `function-call` | gonako / run | 58.10 | 57.77–58.25 | 0.48 | 0.30 | 58.06 | 0.42 | 0.7% |
| `function-call` | lnako / interpreter | 256.43 | 254.78–258.01 | 3.22 | 1.84 | 257.68 | 4.17 | 1.6% |
| `function-call` | lnako / compile | 129.85 | 127.30–132.06 | 4.76 | 2.55 | 138.67 | 29.22 | 21.1% |
| `function-call` | lnako / aot_run | 17.28 | 17.13–17.35 | 0.23 | 0.12 | 17.24 | 0.14 | 0.8% |
| `closure-call` | cnako / run | 110.41 | 109.39–111.70 | 2.31 | 1.29 | 110.72 | 1.80 | 1.6% |
| `closure-call` | gonako / run | 39.68 | 39.38–40.04 | 0.66 | 0.35 | 39.74 | 0.61 | 1.5% |
| `closure-call` | lnako / interpreter | 228.78 | 228.38–231.14 | 2.76 | 0.74 | 229.74 | 1.80 | 0.8% |
| `closure-call` | lnako / compile | 122.04 | 121.48–122.57 | 1.09 | 0.60 | 121.99 | 0.77 | 0.6% |
| `closure-call` | lnako / aot_run | 8.01 | 7.94–8.13 | 0.19 | 0.08 | 8.05 | 0.12 | 1.5% |
| `recursion` | cnako / run | 1,308.26 | 1,281.37–1,333.27 | 51.90 | 31.33 | 1,310.12 | 35.36 | 2.7% |
| `recursion` | gonako / run | 379.00 | 375.79–379.66 | 3.87 | 1.79 | 378.60 | 4.97 | 1.3% |
| `recursion` | lnako / interpreter | 604.95 | 604.35–607.04 | 2.70 | 1.34 | 606.20 | 3.42 | 0.6% |
| `recursion` | lnako / compile | 121.31 | 119.81–122.68 | 2.87 | 1.52 | 121.65 | 2.52 | 2.1% |
| `recursion` | lnako / aot_run | 225.32 | 224.84–226.01 | 1.17 | 0.68 | 226.27 | 2.46 | 1.1% |
| `nbody` | cnako / run | 107.60 | 106.77–108.41 | 1.63 | 0.90 | 107.82 | 2.16 | 2.0% |
| `nbody` | gonako / run | 28.85 | 28.69–29.10 | 0.41 | 0.22 | 28.97 | 0.44 | 1.5% |
| `nbody` | lnako / interpreter | 320.39 | 319.96–321.71 | 1.76 | 0.62 | 321.00 | 1.31 | 0.4% |
| `nbody` | lnako / compile | 239.15 | 237.97–242.12 | 4.15 | 1.53 | 240.67 | 3.56 | 1.5% |
| `nbody` | lnako / aot_run | 19.81 | 19.78–19.92 | 0.14 | 0.07 | 19.83 | 0.13 | 0.7% |
| `array-build` | cnako / run | 88.16 | 86.61–88.81 | 2.19 | 1.05 | 87.60 | 1.48 | 1.7% |
| `array-build` | gonako / run | 31.09 | 30.93–31.23 | 0.30 | 0.18 | 31.27 | 0.74 | 2.4% |
| `array-build` | lnako / interpreter | 160.95 | 160.70–161.63 | 0.94 | 0.37 | 161.46 | 1.34 | 0.8% |
| `array-build` | lnako / compile | 124.09 | 122.21–124.32 | 2.12 | 1.19 | 123.48 | 1.74 | 1.4% |
| `array-build` | lnako / aot_run | 11.71 | 11.67–11.89 | 0.22 | 0.06 | 11.92 | 0.45 | 3.8% |
| `array-scan` | cnako / run | 93.65 | 92.90–94.25 | 1.36 | 0.78 | 93.64 | 1.42 | 1.5% |
| `array-scan` | gonako / run | 53.91 | 53.62–54.46 | 0.84 | 0.32 | 54.29 | 1.06 | 2.0% |
| `array-scan` | lnako / interpreter | 561.11 | 560.07–566.37 | 6.30 | 1.47 | 562.81 | 3.71 | 0.7% |
| `array-scan` | lnako / compile | 132.11 | 129.96–134.51 | 4.56 | 2.54 | 140.64 | 27.29 | 19.4% |
| `array-scan` | lnako / aot_run | 28.85 | 28.80–28.89 | 0.09 | 0.05 | 28.86 | 0.07 | 0.3% |
| `hash-lookup` | cnako / run | 100.11 | 98.94–101.20 | 2.26 | 1.28 | 100.30 | 1.70 | 1.7% |
| `hash-lookup` | gonako / run | 42.33 | 42.12–42.71 | 0.58 | 0.33 | 42.40 | 0.53 | 1.2% |
| `hash-lookup` | lnako / interpreter | 409.42 | 408.70–411.00 | 2.30 | 1.18 | 411.94 | 5.99 | 1.5% |
| `hash-lookup` | lnako / compile | 131.73 | 131.15–132.44 | 1.29 | 0.69 | 131.86 | 0.88 | 0.7% |
| `hash-lookup` | lnako / aot_run | 2,622.63 | 2,616.27–2,627.34 | 11.07 | 6.09 | 2,624.80 | 12.03 | 0.5% |
| `string-concat` | cnako / run | 83.44 | 82.97–84.59 | 1.62 | 0.73 | 83.79 | 1.09 | 1.3% |
| `string-concat` | gonako / run | 20.80 | 20.62–20.96 | 0.34 | 0.18 | 20.83 | 0.37 | 1.8% |
| `string-concat` | c / compile | 85.34 | 84.48–87.04 | 2.56 | 1.55 | 85.77 | 2.01 | 2.3% |
| `string-concat` | c / run | 2.94 | 2.87–3.03 | 0.16 | 0.09 | 2.96 | 0.19 | 6.3% |
| `string-concat` | rust / compile | 168.58 | 167.00–168.91 | 1.91 | 0.88 | 168.12 | 1.10 | 0.7% |
| `string-concat` | rust / run | 3.18 | 3.07–3.27 | 0.20 | 0.11 | 3.21 | 0.19 | 5.9% |
| `string-concat` | lnako / interpreter | 28.84 | 28.69–29.31 | 0.62 | 0.20 | 29.02 | 0.48 | 1.7% |
| `string-concat` | lnako / compile | 119.13 | 118.78–120.16 | 1.38 | 0.45 | 119.70 | 1.40 | 1.2% |
| `string-concat` | lnako / aot_run | 101.62 | 101.41–101.79 | 0.38 | 0.23 | 102.23 | 2.00 | 2.0% |
| `string-builder` | cnako / run | 86.28 | 85.54–88.08 | 2.55 | 1.79 | 86.79 | 2.27 | 2.6% |
| `string-builder` | gonako / run | 18.93 | 18.70–18.98 | 0.28 | 0.12 | 18.84 | 0.19 | 1.0% |
| `string-builder` | c / compile | 84.59 | 83.73–84.78 | 1.05 | 0.44 | 84.47 | 1.17 | 1.4% |
| `string-builder` | c / run | 2.31 | 2.19–2.47 | 0.28 | 0.14 | 2.32 | 0.19 | 8.2% |
| `string-builder` | rust / compile | 172.04 | 166.83–174.77 | 7.94 | 4.97 | 171.32 | 4.48 | 2.6% |
| `string-builder` | rust / run | 2.40 | 2.28–2.48 | 0.20 | 0.11 | 2.43 | 0.18 | 7.5% |
| `string-builder` | lnako / interpreter | 45.65 | 45.57–45.88 | 0.32 | 0.14 | 45.72 | 0.27 | 0.6% |
| `string-builder` | lnako / compile | 120.22 | 119.31–120.64 | 1.32 | 0.85 | 120.17 | 1.30 | 1.1% |
| `string-builder` | lnako / aot_run | 8.60 | 7.83–9.53 | 1.69 | 0.89 | 8.75 | 1.00 | 11.4% |
| `unicode-scan` | cnako / run | 93.84 | 93.02–94.47 | 1.45 | 0.85 | 93.83 | 1.76 | 1.9% |
| `unicode-scan` | gonako / run | 33.68 | 33.26–33.75 | 0.49 | 0.15 | 33.55 | 0.25 | 0.7% |
| `unicode-scan` | lnako / interpreter | 279.19 | 278.51–279.91 | 1.41 | 0.73 | 279.50 | 1.40 | 0.5% |
| `unicode-scan` | lnako / compile | 132.25 | 131.58–133.12 | 1.55 | 0.88 | 133.71 | 4.28 | 3.2% |
| `unicode-scan` | lnako / aot_run | 33.00 | 32.38–33.24 | 0.86 | 0.50 | 32.90 | 0.71 | 2.2% |
| `sieve` | cnako / run | 99.81 | 99.43–100.87 | 1.44 | 0.69 | 100.29 | 1.57 | 1.6% |
| `sieve` | gonako / run | 27.08 | 26.58–27.58 | 1.00 | 0.57 | 27.20 | 0.74 | 2.7% |
| `sieve` | lnako / interpreter | 369.53 | 368.78–369.99 | 1.21 | 0.69 | 369.55 | 1.57 | 0.4% |
| `sieve` | lnako / compile | 152.12 | 151.07–152.69 | 1.61 | 0.84 | 151.85 | 1.29 | 0.9% |
| `sieve` | lnako / aot_run | 18.29 | 18.23–18.66 | 0.43 | 0.07 | 18.67 | 0.77 | 4.1% |
| `binary-trees` | cnako / run | 110.98 | 110.13–113.77 | 3.64 | 1.83 | 112.30 | 3.45 | 3.1% |
| `binary-trees` | gonako / run | 35.20 | 35.10–35.50 | 0.40 | 0.25 | 35.23 | 0.27 | 0.8% |
| `binary-trees` | lnako / interpreter | 35.30 | 35.23–35.78 | 0.55 | 0.21 | 35.51 | 0.46 | 1.3% |
| `binary-trees` | lnako / compile | 145.27 | 143.85–145.48 | 1.63 | 1.18 | 145.22 | 1.99 | 1.4% |
| `binary-trees` | lnako / aot_run | 23.88 | 23.77–23.93 | 0.16 | 0.09 | 24.20 | 1.06 | 4.4% |
| `word-count` | cnako / run | 91.85 | 91.13–93.24 | 2.10 | 1.13 | 92.14 | 1.43 | 1.5% |
| `word-count` | gonako / run | 25.77 | 25.56–26.00 | 0.44 | 0.24 | 25.75 | 0.32 | 1.2% |
| `word-count` | lnako / interpreter | 208.25 | 207.95–209.09 | 1.15 | 0.51 | 208.44 | 0.64 | 0.3% |
| `word-count` | lnako / compile | 151.29 | 150.03–152.06 | 2.03 | 0.94 | 151.06 | 1.14 | 0.8% |
| `word-count` | lnako / aot_run | 15.13 | 14.99–15.20 | 0.21 | 0.13 | 15.21 | 0.41 | 2.7% |
| `json-transform` | cnako / run | 90.02 | 89.10–91.40 | 2.31 | 1.31 | 91.11 | 3.54 | 3.9% |
| `json-transform` | gonako / run | 19.92 | 19.71–20.63 | 0.92 | 0.32 | 20.14 | 0.63 | 3.1% |
| `json-transform` | lnako / interpreter | 54.68 | 54.51–55.90 | 1.39 | 0.25 | 55.40 | 1.19 | 2.1% |
| `json-transform` | lnako / compile | 159.84 | 158.42–166.60 | 8.18 | 2.02 | 163.50 | 8.02 | 4.9% |
| `json-transform` | lnako / aot_run | 8.06 | 7.95–8.10 | 0.15 | 0.09 | 8.05 | 0.19 | 2.3% |
| `file-read` | cnako / run | 83.78 | 82.88–84.33 | 1.45 | 0.87 | 83.70 | 1.01 | 1.2% |
| `file-read` | gonako / run | 13.73 | 13.47–14.49 | 1.02 | 0.51 | 13.97 | 0.66 | 4.8% |
| `file-read` | lnako / interpreter | 7.08 | 7.04–7.25 | 0.20 | 0.12 | 7.19 | 0.32 | 4.5% |
| `file-read` | lnako / compile | 135.21 | 133.82–137.65 | 3.82 | 2.34 | 136.79 | 4.57 | 3.3% |
| `file-read` | lnako / aot_run | 3.10 | 3.00–3.16 | 0.16 | 0.10 | 3.08 | 0.20 | 6.6% |
| `compile-stress-medium` | lnako / compile | 664.91 | 654.28–672.58 | 18.31 | 8.82 | 672.26 | 31.84 | 4.7% |

20ケース・108測定行で期待出力を確認済みです。共有CI・OS・CPUやページキャッシュの影響があるため、環境間の直接順位付けや総合スコアには使用しません。
