# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1787817954813`
- git_commit: `1e24c584748d077648a2dd82337370b7c223a16f`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 31211542 | 31381250 | 31470000 |
| `arithmetic-loop` | `aot_compile` | 5 | 200528125 | 203299958 | 206565750 |
| `arithmetic-loop` | `aot_run` | 5 | 3813667 | 4034292 | 4841458 |
| `array-mutation` | `interpreter` | 5 | 24994750 | 25149458 | 25580292 |
| `array-mutation` | `aot_compile` | 5 | 195266792 | 200812375 | 203300125 |
| `array-mutation` | `aot_run` | 5 | 6061792 | 6666958 | 7126333 |
| `closure-loop` | `interpreter` | 5 | 80389792 | 80471416 | 80806959 |
| `closure-loop` | `aot_compile` | 5 | 206370416 | 207263750 | 212167250 |
| `closure-loop` | `aot_run` | 5 | 3719542 | 4218833 | 5087500 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
