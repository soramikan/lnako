# ベンチマーク結果 — windows / x86_64

[概要と読み方](RESULTS.md) · [元のJSON](2026-09-09-rc-windows-x64-comparison.json)

## 測定条件

| 項目 | 値 |
| --- | --- |
| 測定日時（UTC） | 2026-09-08T15:48:44.437Z |
| 測定コミット | 5dcf585f4db394206fb5480ef6b184d3138c6daf（clean） |
| プロファイル | smoke / warmup 1回 / 測定 3回 |
| AOT / C / Rust 最適化 | O2 |
| CPU | AMD EPYC 9V74 80-Core Processor                 |
| 論理CPU数 | 4 |
| メモリ | 15.99 GiB |
| OS release | 10.0.26100 |
| スイートSHA-256 | 174b77cf2bffd4eb0357ac0471bc0cb9dff2fe70f4e6cbe9c6365914787e8e21 |

### 処理系とコンパイラ

| 処理系 | 区分 | 自己表示バージョン |
| --- | --- | --- |
| lnako | 正式比較 | lnako 0.1.0 |
| cnako | 正式比較 | v3.7.24 |
| gonako | 正式比較 | gonako v3.6.0 (windows/amd64) |
| c | 参考値 | clang version 22.1.8 (https://github.com/llvm/llvm-project ca7933e47d3a3451d81e72ac174dcb5aa28b59d1) |
| rust | 参考値 | rustc 1.98.0 (88d9e12ae 2026-08-18) |

gonako配布版: 3.8.1。配布版とバイナリの自己表示バージョンは別々に記録しています。SHA-256: `e8d064e6f82551118dc5b498d92083ec4ab978199bff9531522cc6d8be224ac7`。
[公式配布元](https://github.com/kujirahand/nadesiko3go/releases/download/3.8.1/gonako-3.8.1-windows-amd64.exe)

## 正式比較：実行時間の中央値

単位は **ms**、小さいほど短時間です。全値にプロセス起動・終了を含み、lnako AOTの事前コンパイルは含みません。† はsteady_stateで中央値200ms未満の測定です。— は未測定・未対応で、0msではありません。

| ケース | cnako | gonako | lnako interpreter | lnako AOT |
| --- | ---: | ---: | ---: | ---: |
| `startup-empty` | 189.73 | 30.74 | 24.37 | 19.82 |
| `startup-hello` | 185.43 | 28.75 | 27.78 | 20.17 |
| `integer-arithmetic` | 215.48 | 181.94 † | 833.30 | 83.04 † |
| `branch-mix` | 230.84 | 220.54 | 1,149.22 | 105.00 † |
| `function-call` | 291.44 | 162.92 † | 381.79 | 56.06 † |
| `closure-call` | 260.75 | 114.43 † | 350.33 | 27.63 † |
| `recursion` | 2,479.89 | 1,031.80 | 890.66 | 258.00 |
| `nbody` | 250.68 | 82.35 † | 446.01 | 37.18 † |
| `array-build` | 213.25 | 100.28 † | 604.08 | 26.41 † |
| `array-scan` | 228.74 | 159.98 † | 1,089.95 | 59.15 † |
| `hash-lookup` | 271.12 | 135.18 † | 565.27 | 83.81 † |
| `string-concat` | 205.80 | 56.50 † | 93.83 † | 93.07 † |
| `string-builder` | 212.86 | 49.59 † | 176.80 † | 28.58 † |
| `unicode-scan` | 224.05 | 100.09 † | 434.94 | 57.68 † |
| `sieve` | 232.39 | 72.89 † | 510.11 | 36.66 † |
| `binary-trees` | 284.33 | 95.55 † | 88.99 † | 40.83 † |
| `word-count` | 223.70 | 69.36 † | 331.42 | 44.55 † |
| `json-transform` | 221.56 | 50.66 † | 104.05 † | 35.84 † |
| `file-read` | 212.59 | 36.32 † | 33.82 † | 22.77 † |

## 参考値：C・Rustの実行時間

同じ入力・反復数・期待出力に揃えた別言語の実装です。処理系の正式比較とは区別します。単位はmsで、事前コンパイルを含みません。文字列の反復コピーと可変構築は別のケースとして扱います。

| ケース | C | Rust |
| --- | ---: | ---: |
| `integer-arithmetic` | 19.69 † | 22.21 † |
| `string-concat` | 20.85 † | 22.80 † |
| `string-builder` | 18.32 † | 20.03 † |

## コンパイル時間と実行ファイルサイズ

時間はms、サイズはbytesです。cnako・gonakoのソース実行と、lnako・C・Rustの実行ファイル生成を同一のコンパイル測定として扱いません。

| ケース | 処理系 | 中央値 | P25–P75 | 実行ファイル（bytes） |
| --- | --- | ---: | ---: | ---: |
| `startup-empty` | lnako | 254.73 | 251.75–287.27 | 8,958,976 |
| `startup-hello` | lnako | 255.71 | 251.79–259.02 | 8,960,000 |
| `integer-arithmetic` | c | 191.48 | 191.46–194.85 | 148,992 |
| `integer-arithmetic` | rust | 406.60 | 401.07–418.67 | 141,312 |
| `integer-arithmetic` | lnako | 290.98 | 286.41–291.18 | 8,968,704 |
| `branch-mix` | lnako | 311.85 | 307.24–318.06 | 8,969,728 |
| `function-call` | lnako | 286.89 | 283.14–287.57 | 8,968,192 |
| `closure-call` | lnako | 275.43 | 274.33–276.67 | 8,964,096 |
| `recursion` | lnako | 278.64 | 278.00–279.29 | 8,967,680 |
| `nbody` | lnako | 409.29 | 408.86–409.38 | 8,980,992 |
| `array-build` | lnako | 282.90 | 280.47–283.52 | 8,969,216 |
| `array-scan` | lnako | 317.68 | 313.11–341.29 | 8,970,752 |
| `hash-lookup` | lnako | 314.06 | 305.59–319.55 | 8,972,288 |
| `string-concat` | c | 196.95 | 195.43–201.76 | 148,480 |
| `string-concat` | rust | 379.61 | 368.04–383.24 | 140,800 |
| `string-concat` | lnako | 302.86 | 294.50–306.53 | 8,969,728 |
| `string-builder` | c | 194.69 | 194.29–201.27 | 148,480 |
| `string-builder` | rust | 374.78 | 370.94–377.24 | 140,288 |
| `string-builder` | lnako | 288.90 | 285.14–296.72 | 8,971,264 |
| `unicode-scan` | lnako | 306.55 | 302.54–306.72 | 8,969,728 |
| `sieve` | lnako | 328.74 | 325.40–336.27 | 8,971,264 |
| `binary-trees` | lnako | 328.19 | 324.32–328.82 | 8,974,848 |
| `word-count` | lnako | 348.23 | 345.78–363.13 | 8,971,264 |
| `json-transform` | lnako | 332.46 | 330.90–343.11 | 8,974,336 |
| `file-read` | lnako | 312.80 | 312.64–315.44 | 8,969,216 |

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
| `startup-empty` | cnako / run | 189.73 | 189.23–190.46 | 1.24 | 1.01 | 189.88 | 1.02 | 0.5% |
| `startup-empty` | gonako / run | 30.74 | 30.41–31.46 | 1.05 | 0.66 | 31.00 | 0.88 | 2.8% |
| `startup-empty` | lnako / interpreter | 24.37 | 24.06–24.88 | 0.82 | 0.62 | 24.51 | 0.68 | 2.8% |
| `startup-empty` | lnako / compile | 254.73 | 251.75–287.27 | 35.53 | 5.97 | 274.44 | 32.18 | 11.7% |
| `startup-empty` | lnako / aot_run | 19.82 | 19.70–20.24 | 0.54 | 0.24 | 20.02 | 0.46 | 2.3% |
| `startup-hello` | cnako / run | 185.43 | 182.86–190.70 | 7.84 | 5.15 | 187.23 | 6.53 | 3.5% |
| `startup-hello` | gonako / run | 28.75 | 28.54–30.50 | 1.95 | 0.40 | 29.78 | 1.75 | 5.9% |
| `startup-hello` | lnako / interpreter | 27.78 | 26.68–28.66 | 1.98 | 1.75 | 27.63 | 1.62 | 5.9% |
| `startup-hello` | lnako / compile | 255.71 | 251.79–259.02 | 7.24 | 6.64 | 255.30 | 5.92 | 2.3% |
| `startup-hello` | lnako / aot_run | 20.17 | 20.16–20.65 | 0.49 | 0.01 | 20.49 | 0.46 | 2.2% |
| `integer-arithmetic` | cnako / run | 215.48 | 213.34–215.75 | 2.42 | 0.55 | 214.23 | 2.16 | 1.0% |
| `integer-arithmetic` | gonako / run | 181.94 | 181.85–183.14 | 1.29 | 0.19 | 182.68 | 1.18 | 0.6% |
| `integer-arithmetic` | c / compile | 191.48 | 191.46–194.85 | 3.39 | 0.03 | 193.71 | 3.19 | 1.6% |
| `integer-arithmetic` | c / run | 19.69 | 19.64–19.72 | 0.08 | 0.06 | 19.68 | 0.06 | 0.3% |
| `integer-arithmetic` | rust / compile | 406.60 | 401.07–418.67 | 17.60 | 11.05 | 410.96 | 14.70 | 3.6% |
| `integer-arithmetic` | rust / run | 22.21 | 22.15–22.54 | 0.39 | 0.13 | 22.39 | 0.34 | 1.5% |
| `integer-arithmetic` | lnako / interpreter | 833.30 | 830.21–845.65 | 15.44 | 6.18 | 839.47 | 13.34 | 1.6% |
| `integer-arithmetic` | lnako / compile | 290.98 | 286.41–291.18 | 4.76 | 0.40 | 288.07 | 4.40 | 1.5% |
| `integer-arithmetic` | lnako / aot_run | 83.04 | 82.08–83.34 | 1.26 | 0.62 | 82.60 | 1.08 | 1.3% |
| `branch-mix` | cnako / run | 230.84 | 227.63–241.59 | 13.96 | 6.41 | 235.87 | 11.94 | 5.1% |
| `branch-mix` | gonako / run | 220.54 | 220.40–221.35 | 0.96 | 0.29 | 220.99 | 0.84 | 0.4% |
| `branch-mix` | lnako / interpreter | 1,149.22 | 1,135.34–1,175.95 | 40.60 | 27.74 | 1,157.79 | 33.70 | 2.9% |
| `branch-mix` | lnako / compile | 311.85 | 307.24–318.06 | 10.83 | 9.23 | 312.91 | 8.87 | 2.8% |
| `branch-mix` | lnako / aot_run | 105.00 | 103.05–108.88 | 5.83 | 3.90 | 106.28 | 4.85 | 4.6% |
| `function-call` | cnako / run | 291.44 | 286.55–300.58 | 14.03 | 9.78 | 294.28 | 11.63 | 4.0% |
| `function-call` | gonako / run | 162.92 | 162.25–163.17 | 0.93 | 0.50 | 162.64 | 0.78 | 0.5% |
| `function-call` | lnako / interpreter | 381.79 | 373.06–384.65 | 11.59 | 5.71 | 377.87 | 9.86 | 2.6% |
| `function-call` | lnako / compile | 286.89 | 283.14–287.57 | 4.43 | 1.36 | 284.84 | 3.90 | 1.4% |
| `function-call` | lnako / aot_run | 56.06 | 55.46–56.35 | 0.89 | 0.58 | 55.85 | 0.74 | 1.3% |
| `closure-call` | cnako / run | 260.75 | 258.61–265.61 | 7.00 | 4.28 | 262.56 | 5.86 | 2.2% |
| `closure-call` | gonako / run | 114.43 | 112.35–115.02 | 2.66 | 1.17 | 113.44 | 2.29 | 2.0% |
| `closure-call` | lnako / interpreter | 350.33 | 331.44–357.59 | 26.15 | 14.51 | 342.57 | 22.05 | 6.4% |
| `closure-call` | lnako / compile | 275.43 | 274.33–276.67 | 2.33 | 2.20 | 275.52 | 1.91 | 0.7% |
| `closure-call` | lnako / aot_run | 27.63 | 27.23–28.26 | 1.03 | 0.80 | 27.78 | 0.85 | 3.0% |
| `recursion` | cnako / run | 2,479.89 | 2,460.00–2,512.58 | 52.58 | 39.78 | 2,488.42 | 43.35 | 1.7% |
| `recursion` | gonako / run | 1,031.80 | 1,031.41–1,033.10 | 1.69 | 0.76 | 1,032.41 | 1.45 | 0.1% |
| `recursion` | lnako / interpreter | 890.66 | 865.84–891.59 | 25.76 | 1.87 | 874.73 | 23.86 | 2.7% |
| `recursion` | lnako / compile | 278.64 | 278.00–279.29 | 1.28 | 1.28 | 278.65 | 1.05 | 0.4% |
| `recursion` | lnako / aot_run | 258.00 | 254.95–259.89 | 4.94 | 3.78 | 257.23 | 4.07 | 1.6% |
| `nbody` | cnako / run | 250.68 | 249.62–258.11 | 8.49 | 2.10 | 254.93 | 7.56 | 3.0% |
| `nbody` | gonako / run | 82.35 | 80.74–83.83 | 3.09 | 2.96 | 82.26 | 2.52 | 3.1% |
| `nbody` | lnako / interpreter | 446.01 | 441.90–467.86 | 25.95 | 8.21 | 457.84 | 22.78 | 5.0% |
| `nbody` | lnako / compile | 409.29 | 408.86–409.38 | 0.53 | 0.19 | 409.06 | 0.46 | 0.1% |
| `nbody` | lnako / aot_run | 37.18 | 36.33–37.50 | 1.17 | 0.65 | 36.83 | 0.99 | 2.7% |
| `array-build` | cnako / run | 213.25 | 211.09–214.31 | 3.22 | 2.12 | 212.52 | 2.68 | 1.3% |
| `array-build` | gonako / run | 100.28 | 96.37–100.36 | 3.98 | 0.15 | 97.73 | 3.72 | 3.8% |
| `array-build` | lnako / interpreter | 604.08 | 598.68–617.56 | 18.88 | 10.80 | 609.47 | 15.88 | 2.6% |
| `array-build` | lnako / compile | 282.90 | 280.47–283.52 | 3.05 | 1.24 | 281.69 | 2.63 | 0.9% |
| `array-build` | lnako / aot_run | 26.41 | 26.35–27.87 | 1.52 | 0.11 | 27.35 | 1.40 | 5.1% |
| `array-scan` | cnako / run | 228.74 | 223.19–230.38 | 7.18 | 3.27 | 226.13 | 6.15 | 2.7% |
| `array-scan` | gonako / run | 159.98 | 156.58–160.32 | 3.74 | 0.69 | 157.94 | 3.37 | 2.1% |
| `array-scan` | lnako / interpreter | 1,089.95 | 1,082.02–1,108.75 | 26.73 | 15.86 | 1,097.19 | 22.42 | 2.0% |
| `array-scan` | lnako / compile | 317.68 | 313.11–341.29 | 28.17 | 9.14 | 330.37 | 24.69 | 7.5% |
| `array-scan` | lnako / aot_run | 59.15 | 58.32–59.85 | 1.53 | 1.40 | 59.07 | 1.25 | 2.1% |
| `hash-lookup` | cnako / run | 271.12 | 269.80–274.30 | 4.51 | 2.65 | 272.36 | 3.78 | 1.4% |
| `hash-lookup` | gonako / run | 135.18 | 132.85–137.41 | 4.56 | 4.44 | 135.11 | 3.72 | 2.8% |
| `hash-lookup` | lnako / interpreter | 565.27 | 559.08–576.19 | 17.11 | 12.37 | 568.43 | 14.15 | 2.5% |
| `hash-lookup` | lnako / compile | 314.06 | 305.59–319.55 | 13.96 | 10.98 | 312.07 | 11.48 | 3.7% |
| `hash-lookup` | lnako / aot_run | 83.81 | 82.83–84.83 | 2.00 | 1.96 | 83.84 | 1.63 | 1.9% |
| `string-concat` | cnako / run | 205.80 | 204.42–206.63 | 2.21 | 1.66 | 205.43 | 1.83 | 0.9% |
| `string-concat` | gonako / run | 56.50 | 55.58–57.83 | 2.25 | 1.83 | 56.78 | 1.85 | 3.3% |
| `string-concat` | c / compile | 196.95 | 195.43–201.76 | 6.33 | 3.04 | 199.14 | 5.39 | 2.7% |
| `string-concat` | c / run | 20.85 | 20.25–21.37 | 1.12 | 1.04 | 20.79 | 0.91 | 4.4% |
| `string-concat` | rust / compile | 379.61 | 368.04–383.24 | 15.20 | 7.25 | 374.31 | 12.97 | 3.5% |
| `string-concat` | rust / run | 22.80 | 22.29–23.31 | 1.02 | 1.01 | 22.80 | 0.83 | 3.6% |
| `string-concat` | lnako / interpreter | 93.83 | 93.31–94.30 | 0.98 | 0.94 | 93.80 | 0.80 | 0.9% |
| `string-concat` | lnako / compile | 302.86 | 294.50–306.53 | 12.03 | 7.35 | 299.74 | 10.07 | 3.4% |
| `string-concat` | lnako / aot_run | 93.07 | 91.82–93.28 | 1.47 | 0.43 | 92.38 | 1.30 | 1.4% |
| `string-builder` | cnako / run | 212.86 | 210.59–213.71 | 3.12 | 1.70 | 211.91 | 2.63 | 1.2% |
| `string-builder` | gonako / run | 49.59 | 49.33–50.28 | 0.96 | 0.53 | 49.88 | 0.81 | 1.6% |
| `string-builder` | c / compile | 194.69 | 194.29–201.27 | 6.98 | 0.80 | 198.81 | 6.40 | 3.2% |
| `string-builder` | c / run | 18.32 | 18.22–18.39 | 0.17 | 0.14 | 18.30 | 0.14 | 0.7% |
| `string-builder` | rust / compile | 374.78 | 370.94–377.24 | 6.30 | 4.92 | 373.86 | 5.18 | 1.4% |
| `string-builder` | rust / run | 20.03 | 20.02–20.45 | 0.43 | 0.02 | 20.30 | 0.40 | 2.0% |
| `string-builder` | lnako / interpreter | 176.80 | 174.62–178.35 | 3.73 | 3.11 | 176.39 | 3.06 | 1.7% |
| `string-builder` | lnako / compile | 288.90 | 285.14–296.72 | 11.58 | 7.53 | 291.60 | 9.65 | 3.3% |
| `string-builder` | lnako / aot_run | 28.58 | 28.10–28.60 | 0.49 | 0.03 | 28.27 | 0.46 | 1.6% |
| `unicode-scan` | cnako / run | 224.05 | 223.32–224.14 | 0.83 | 0.18 | 223.62 | 0.74 | 0.3% |
| `unicode-scan` | gonako / run | 100.09 | 97.96–101.54 | 3.58 | 2.90 | 99.64 | 2.94 | 3.0% |
| `unicode-scan` | lnako / interpreter | 434.94 | 423.65–439.85 | 16.20 | 9.81 | 430.68 | 13.56 | 3.1% |
| `unicode-scan` | lnako / compile | 306.55 | 302.54–306.72 | 4.18 | 0.32 | 303.98 | 3.86 | 1.3% |
| `unicode-scan` | lnako / aot_run | 57.68 | 57.18–57.99 | 0.81 | 0.63 | 57.56 | 0.67 | 1.2% |
| `sieve` | cnako / run | 232.39 | 229.51–234.52 | 5.01 | 4.26 | 231.89 | 4.11 | 1.8% |
| `sieve` | gonako / run | 72.89 | 72.02–73.77 | 1.75 | 1.74 | 72.90 | 1.43 | 2.0% |
| `sieve` | lnako / interpreter | 510.11 | 499.75–517.01 | 17.26 | 13.79 | 507.80 | 14.19 | 2.8% |
| `sieve` | lnako / compile | 328.74 | 325.40–336.27 | 10.87 | 6.67 | 331.54 | 9.10 | 2.7% |
| `sieve` | lnako / aot_run | 36.66 | 34.72–36.85 | 2.13 | 0.37 | 35.49 | 1.93 | 5.4% |
| `binary-trees` | cnako / run | 284.33 | 284.28–284.66 | 0.38 | 0.09 | 284.52 | 0.34 | 0.1% |
| `binary-trees` | gonako / run | 95.55 | 94.89–96.47 | 1.58 | 1.32 | 95.72 | 1.30 | 1.4% |
| `binary-trees` | lnako / interpreter | 88.99 | 88.93–91.58 | 2.65 | 0.13 | 90.67 | 2.47 | 2.7% |
| `binary-trees` | lnako / compile | 328.19 | 324.32–328.82 | 4.50 | 1.26 | 326.03 | 3.98 | 1.2% |
| `binary-trees` | lnako / aot_run | 40.83 | 40.68–42.18 | 1.50 | 0.30 | 41.63 | 1.35 | 3.2% |
| `word-count` | cnako / run | 223.70 | 221.58–224.13 | 2.56 | 0.86 | 222.57 | 2.23 | 1.0% |
| `word-count` | gonako / run | 69.36 | 69.31–70.15 | 0.84 | 0.09 | 69.86 | 0.77 | 1.1% |
| `word-count` | lnako / interpreter | 331.42 | 315.45–336.99 | 21.53 | 11.13 | 324.48 | 18.25 | 5.6% |
| `word-count` | lnako / compile | 348.23 | 345.78–363.13 | 17.36 | 4.90 | 356.53 | 15.34 | 4.3% |
| `word-count` | lnako / aot_run | 44.55 | 44.17–44.86 | 0.69 | 0.61 | 44.50 | 0.57 | 1.3% |
| `json-transform` | cnako / run | 221.56 | 220.00–226.61 | 6.60 | 3.13 | 223.88 | 5.64 | 2.5% |
| `json-transform` | gonako / run | 50.66 | 50.45–52.21 | 1.76 | 0.41 | 51.55 | 1.57 | 3.0% |
| `json-transform` | lnako / interpreter | 104.05 | 101.85–108.73 | 6.89 | 4.40 | 105.70 | 5.74 | 5.4% |
| `json-transform` | lnako / compile | 332.46 | 330.90–343.11 | 12.21 | 3.13 | 338.52 | 10.85 | 3.2% |
| `json-transform` | lnako / aot_run | 35.84 | 35.55–36.11 | 0.55 | 0.54 | 35.83 | 0.45 | 1.3% |
| `file-read` | cnako / run | 212.59 | 211.29–212.95 | 1.66 | 0.73 | 211.96 | 1.43 | 0.7% |
| `file-read` | gonako / run | 36.32 | 35.53–36.56 | 1.04 | 0.48 | 35.95 | 0.89 | 2.5% |
| `file-read` | lnako / interpreter | 33.82 | 32.45–34.05 | 1.60 | 0.47 | 33.06 | 1.41 | 4.3% |
| `file-read` | lnako / compile | 312.80 | 312.64–315.44 | 2.80 | 0.31 | 314.46 | 2.56 | 0.8% |
| `file-read` | lnako / aot_run | 22.77 | 22.58–22.79 | 0.21 | 0.04 | 22.66 | 0.19 | 0.8% |

19ケース・107測定行で期待出力を確認済みです。共有CI・OS・CPUやページキャッシュの影響があるため、環境間の直接順位付けや総合スコアには使用しません。
