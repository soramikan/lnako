# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788141646614`
- git_commit: `7fb5ca548151322c6e687256f4376de9b249806c`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 29226208 | 29287792 | 29505792 |
| `arithmetic-loop` | `aot_compile` | 3 | 190248125 | 191758083 | 195587042 |
| `arithmetic-loop` | `aot_run` | 3 | 3587334 | 5298750 | 6190417 |
| `array-mutation` | `interpreter` | 3 | 22526708 | 24019709 | 28649333 |
| `array-mutation` | `aot_compile` | 3 | 195328292 | 195998541 | 197963333 |
| `array-mutation` | `aot_run` | 3 | 3886708 | 5485209 | 9096791 |
| `closure-loop` | `interpreter` | 3 | 75620209 | 75755709 | 75937959 |
| `closure-loop` | `aot_compile` | 3 | 201607917 | 201896125 | 202697333 |
| `closure-loop` | `aot_run` | 3 | 5024459 | 6352542 | 8108416 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
