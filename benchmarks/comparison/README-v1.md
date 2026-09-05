# 旧ベンチマーク v1 の記録

以下は過去の測定です。起動時間を含み、算術ループの定数畳み込みや文字列構築方式の差があるため、言語間の処理性能の順位を示すものとしては使用しません。

以下は同一アルゴリズムを `cnako` (Node.js 版なでしこ3)、`gonako` (Go 版なでしこ3)、Python、C、Rust、`lnako` (interpreter / AOT) で計測した結果です。単位はミリ秒（ms）で、warmup 1回 + 3サンプルの中央値を記載しています。

計測環境: GitHub Actions `macos-15` / arm64（[`.github/workflows/comparison-benchmark.yml`](../../.github/workflows/comparison-benchmark.yml) 実行分、commit `d0bb8bc`）、LLVM/LLD 22.1.8、Zig 0.16.0、cnako 3.8.1、Python 3.14.7、rustc 1.98.1、clang 22.1.8、`lnako` AOT および C / Rust は `-O2`。

| ケース | cnako | gonako | Python | C (run) | Rust (run) | lnako interpreter | lnako AOT run |
|---|---:|---:|---:|---:|---:|---:|---:|
| arithmetic-loop | 77.77 | 12.62 | 21.30 | 1.72 | 2.42 | 19.91 | 2.62 |
| array-mutation | 80.04 | 13.35 | 21.70 | 1.80 | 2.17 | 5.35 | 2.42 |
| closure-loop | 83.59 | 15.14 | 21.56 | 1.60 | 2.01 | 36.20 | 3.10 |
| recursion | 3984.63 | 307.86 | 146.94 | 4.87 | 4.96 | 2557.03 | 358.36 |
| string-bench | 78.03 | 24.60 | 22.82 | 1.93 | 2.06 | 105.79 | 150.24 |
`lnako` は AOT 実行時にネイティブコンパイルを活かし、多くのケースで interpreter より高速に動作します。macOS arm64・Linux x64・Windows x64 の全ターゲット生データは各実行の Actions artifact（30日保持）から取得できます。最新の結果は [`.github/workflows/comparison-benchmark.yml`](../../.github/workflows/comparison-benchmark.yml) から実行できます。
