# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788020069763`
- git_commit: `0cdf70641e74f8d98ea099b11c759c7c05ef4ce3`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 29806000 | 30177458 | 30454458 |
| `arithmetic-loop` | `aot_compile` | 5 | 204522375 | 207506667 | 210612000 |
| `arithmetic-loop` | `aot_run` | 5 | 3194375 | 3401958 | 5393834 |
| `array-mutation` | `interpreter` | 5 | 23890333 | 23993291 | 24384750 |
| `array-mutation` | `aot_compile` | 5 | 199196625 | 206098625 | 210376459 |
| `array-mutation` | `aot_run` | 5 | 3189667 | 3225625 | 4527917 |
| `closure-loop` | `interpreter` | 5 | 77380750 | 78164709 | 78389041 |
| `closure-loop` | `aot_compile` | 5 | 211482458 | 212349166 | 221745500 |
| `closure-loop` | `aot_run` | 5 | 5348458 | 6073208 | 6892250 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
