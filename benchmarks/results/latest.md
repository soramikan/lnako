# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788096159203`
- git_commit: `8ba07e387f2b584a33a0c455b651f21b2c6fb76`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 29617000 | 29899250 | 30058625 |
| `arithmetic-loop` | `aot_compile` | 5 | 202270750 | 203449625 | 206773083 |
| `arithmetic-loop` | `aot_run` | 5 | 4064125 | 4496959 | 4936333 |
| `array-mutation` | `interpreter` | 5 | 24094667 | 24431750 | 29151583 |
| `array-mutation` | `aot_compile` | 5 | 202253209 | 203269042 | 203511166 |
| `array-mutation` | `aot_run` | 5 | 3967042 | 4412833 | 6081917 |
| `closure-loop` | `interpreter` | 5 | 75921000 | 76194208 | 76548250 |
| `closure-loop` | `aot_compile` | 5 | 207369167 | 207895458 | 209371042 |
| `closure-loop` | `aot_run` | 5 | 4144125 | 4859875 | 5586625 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
