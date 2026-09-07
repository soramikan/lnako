# ベンチマーク結果

正式比較はcnako・gonako・lnako、別言語の参考値はC・Rustです。測定対象は`02457acce036c239d12313da6bd528dd22e48f6b`、[比較CI 34093414459](https://github.com/soramikan/lnako/actions/runs/34093414459)の3 OS測定を保存しています。

正式suiteは実行19ケースとコンパイル専用1ケース、各OSで108測定行です。warmup 3回後に10回測定し、全ケースの期待出力を照合しています。追加診断は12ケース・48測定行、warmup 1回・測定3回です。

## 環境と生データ

| CI環境 | CPU / 論理CPU数 | 正式20ケース | 診断12ケース |
| --- | --- | --- | --- |
| Linux x86_64 | AMD EPYC 7763 64-Core Processor / 4 | [JSON](2026-09-07-m8-m15-linux-x64-comparison.json) | [JSON](2026-09-07-m8-m15-linux-x64-diagnostics.json) |
| Windows x86_64 | AMD EPYC 7763 64-Core Processor / 4 | [JSON](2026-09-07-m8-m15-windows-x64-comparison.json) | [JSON](2026-09-07-m8-m15-windows-x64-diagnostics.json) |
| macOS arm64 | Apple M1 (Virtual) / 3 | [JSON](2026-09-07-m8-m15-macos-arm64-comparison.json) | [JSON](2026-09-07-m8-m15-macos-arm64-diagnostics.json) |

JSONはCI artifactの変更していないコピーで、測定順のraw samples、四分位範囲、MAD、CV、source/compiler/binary hashとtoolchainを含みます。[artifact index](2026-09-07-m8-m15-artifacts.json)には保存ファイルのSHA-256があります。CIのartifact保持期限後も参照できます。

## 測定条件

- lnakoはReleaseSafe、AOTはO2、LLVM/LLD 22.1.8を使用しています。
- cnakoは互換基準の3.7.24です。gonakoは[3.8.1配布版](https://github.com/kujirahand/nadesiko3go/releases/tag/3.8.1)をSHA-256で固定しています。gonakoの自己表示は3.6.0であり、配布版・自己表示・バイナリhashを区別します。
- gonakoの19実行ケースは期待出力が一致しています。6ケースは共通ソース、13ケースは引数の取り出しを調整したソースです。入力・反復数・計算内容・正解は同じで、調整したソースもcnakoとlnako Interpreterで照合しています。
- 実行時間はprocessの起動から終了までです。Interpreterは解析と実行、AOT・C・Rustは事前コンパイル済み実行ファイルの起動を測ります。setup、配列・辞書の構築などもcase全体の時間に含みます。
- `steady_state`も起動を含む反復処理全体の時間です。200 ms未満は起動時間やrunner負荷に敏感で、純粋なkernel速度や長時間常駐時の性能とは区別してください。
- OS間の直接順位付けはせず、同じ環境・同じcaseで比較します。counter有効のCPU/GC診断は通常benchmarkとは別実行です。

## 正式比較

中央値の単位はms、小さいほど短時間です。READMEは分野のバランスを考えた9実行ケースを選び、ここでは全19実行ケースを示します。

### Linux x86_64

| ケース | cnako | gonako | lnako Interpreter | lnako AOT |
| --- | ---: | ---: | ---: | ---: |
| `startup-empty` | 101.82 | 6.39 | 2.01 | 1.70 |
| `startup-hello` | 107.44 | 6.40 | 2.05 | 1.72 |
| `integer-arithmetic` | 132.15 | 131.97 | 732.34 | 57.85 |
| `branch-mix` | 138.16 | 166.17 | 1,043.75 | 75.27 |
| `function-call` | 172.14 | 115.27 | 319.98 | 32.42 |
| `closure-call` | 155.02 | 69.27 | 281.26 | 9.33 |
| `recursion` | 1,599.77 | 808.91 | 719.70 | 224.54 |
| `nbody` | 157.98 | 47.52 | 397.93 | 15.00 |
| `array-build` | 122.50 | 56.28 | 222.90 | 5.80 |
| `array-scan` | 129.51 | 111.86 | 702.28 | 26.15 |
| `hash-lookup` | 142.47 | 72.37 | 498.49 | 48.68 |
| `string-concat` | 115.47 | 22.42 | 57.50 | 28.80 |
| `string-builder` | 118.79 | 23.25 | 64.67 | 3.84 |
| `unicode-scan` | 131.16 | 59.09 | 339.71 | 31.36 |
| `sieve` | 136.49 | 41.24 | 446.76 | 14.19 |
| `binary-trees` | 160.93 | 51.33 | 49.29 | 16.98 |
| `word-count` | 129.80 | 37.40 | 250.90 | 15.69 |
| `json-transform` | 128.60 | 22.16 | 69.04 | 7.13 |
| `file-read` | 116.34 | 8.92 | 6.86 | 2.16 |

### Windows x86_64

| ケース | cnako | gonako | lnako Interpreter | lnako AOT |
| --- | ---: | ---: | ---: | ---: |
| `startup-empty` | 182.81 | 29.62 | 26.92 | 24.62 |
| `startup-hello` | 203.98 | 29.09 | 26.24 | 20.56 |
| `integer-arithmetic` | 318.95 | 175.93 | 970.71 | 83.36 |
| `branch-mix` | 230.78 | 191.06 | 1,210.54 | 96.93 |
| `function-call` | 277.11 | 147.93 | 381.34 | 52.64 |
| `closure-call` | 253.86 | 107.94 | 347.65 | 27.86 |
| `recursion` | 2,418.50 | 957.83 | 755.71 | 248.22 |
| `nbody` | 237.36 | 72.18 | 474.21 | 33.51 |
| `array-build` | 202.72 | 80.86 | 596.70 | 27.48 |
| `array-scan` | 215.18 | 133.93 | 1,118.74 | 46.27 |
| `hash-lookup` | 224.70 | 100.86 | 593.91 | 83.66 |
| `string-concat` | 203.92 | 52.66 | 82.11 | 85.21 |
| `string-builder` | 203.29 | 46.01 | 175.55 | 23.89 |
| `unicode-scan` | 218.07 | 86.53 | 448.81 | 54.56 |
| `sieve` | 227.97 | 82.20 | 534.93 | 35.03 |
| `binary-trees` | 257.30 | 87.70 | 69.59 | 37.67 |
| `word-count` | 231.72 | 69.25 | 335.90 | 37.81 |
| `json-transform` | 230.75 | 47.65 | 105.89 | 29.74 |
| `file-read` | 201.61 | 32.02 | 31.16 | 21.18 |

### macOS arm64

| ケース | cnako | gonako | lnako Interpreter | lnako AOT |
| --- | ---: | ---: | ---: | ---: |
| `startup-empty` | 91.48 | 14.17 | 4.16 | 1.88 |
| `startup-hello` | 79.21 | 12.14 | 2.85 | 1.88 |
| `integer-arithmetic` | 102.06 | 79.00 | 533.90 | 31.25 |
| `branch-mix` | 112.91 | 105.79 | 753.30 | 44.83 |
| `function-call` | 118.48 | 60.57 | 231.82 | 15.26 |
| `closure-call` | 114.92 | 41.99 | 207.70 | 5.10 |
| `recursion` | 1,322.77 | 401.55 | 425.76 | 89.60 |
| `nbody` | 104.08 | 28.77 | 280.94 | 7.53 |
| `array-build` | 88.37 | 33.17 | 150.28 | 6.04 |
| `array-scan` | 96.35 | 58.65 | 503.47 | 13.69 |
| `hash-lookup` | 100.24 | 46.02 | 367.16 | 45.18 |
| `string-concat` | 87.16 | 21.66 | 28.85 | 60.09 |
| `string-builder` | 89.47 | 18.70 | 43.49 | 3.31 |
| `unicode-scan` | 89.83 | 34.22 | 249.30 | 31.84 |
| `sieve` | 98.67 | 26.90 | 322.50 | 6.51 |
| `binary-trees` | 111.31 | 36.90 | 29.21 | 11.64 |
| `word-count` | 93.51 | 25.69 | 184.87 | 13.41 |
| `json-transform` | 90.39 | 20.09 | 48.66 | 7.45 |
| `file-read` | 83.42 | 13.42 | 5.63 | 2.68 |

## コンパイル時間

`compile-stress-medium`のネイティブ実行ファイル生成時間です。実行時間とは混ぜません。gonakoの`build`は梱包、`gengo`はGoソース生成で、lnakoのコンパイルと同一工程ではないため未比較です。

| ケース | Linux x86_64 | Windows x86_64 | macOS arm64 |
| --- | ---: | ---: | ---: |
| `compile-stress-medium` | 443.40 | 623.21 | 387.22 |

## C・Rustの参考比較

同じ入力・反復数・期待出力の3ケースに限定し、最適化O2で実行しています。CはClang 22.1.8、Rustは1.98.0です。integer-arithmeticは同一LCG/checksum、string-concatは毎回新しい領域へコピーするimmutable連結、string-builderは文字列構築を比較します。builderは言語ごとの自然な実装を使い、なでしこは配列追加と一括結合、C/Rustは可変bufferです。他ケースのC/Rustは未測定です。

| CI環境 | ケース | lnako AOT | C | Rust |
| --- | --- | ---: | ---: | ---: |
| Linux x86_64 | `integer-arithmetic` | 57.85 | 2.05 | 2.24 |
| Linux x86_64 | `string-concat` | 28.80 | 2.26 | 2.47 |
| Linux x86_64 | `string-builder` | 3.84 | 1.61 | 1.79 |
| Windows x86_64 | `integer-arithmetic` | 83.36 | 24.18 | 25.57 |
| Windows x86_64 | `string-concat` | 85.21 | 20.30 | 20.01 |
| Windows x86_64 | `string-builder` | 23.89 | 18.76 | 17.67 |
| macOS arm64 | `integer-arithmetic` | 31.25 | 1.86 | 2.19 |
| macOS arm64 | `string-concat` | 60.09 | 2.71 | 2.65 |
| macOS arm64 | `string-builder` | 3.31 | 2.06 | 1.74 |

## 分析と再測定

[3 OSの判定・Windows CPU解析・GC/allocator診断](../PERFORMANCE_RESULTS_M8_M15.md)には、性能目標の達成・未達と計測範囲を記載しています。[入力一覧と実行手順](../../benchmarks/README.md)から再測定できます。

## 過去のCI測定

過去のCI結果は測定commit・条件が異なる保存記録です。現在の代表値と混ぜて比較しないでください。

| 保存日 | Linux | Windows | macOS |
| --- | --- | --- | --- |
| 2026-09-05 | [記録](2026-09-05-linux-x64.md) | [記録](2026-09-05-windows-x64.md) | [記録](2026-09-05-macos-arm64.md) |
| 2026-09-06 | [記録](2026-09-06-linux-x64.md) | [記録](2026-09-06-windows-x64.md) | [記録](2026-09-06-macos-arm64.md) |
| 2026-09-07 | [記録](2026-09-07-linux-x64.md) | [記録](2026-09-07-windows-x64.md) | [記録](2026-09-07-macos-arm64.md) |
