# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788087332714`
- git_commit: `3c132b7996bb0c1a7dabe9e9d229554b9c33c259`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 29231625 | 29697875 | 29925375 |
| `arithmetic-loop` | `aot_compile` | 5 | 194870375 | 195727875 | 207892084 |
| `arithmetic-loop` | `aot_run` | 5 | 3225917 | 3377917 | 4020583 |
| `array-mutation` | `interpreter` | 5 | 23202750 | 23496667 | 23831500 |
| `array-mutation` | `aot_compile` | 5 | 194154166 | 195693042 | 200921959 |
| `array-mutation` | `aot_run` | 5 | 3043125 | 3093209 | 7680084 |
| `closure-loop` | `interpreter` | 5 | 77012542 | 77165375 | 77634375 |
| `closure-loop` | `aot_compile` | 5 | 201759208 | 202575791 | 204865292 |
| `closure-loop` | `aot_run` | 5 | 3801125 | 3999292 | 4455833 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
