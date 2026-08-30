# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788091052943`
- git_commit: `d6a269e2891537547ee3dd496f79bed0ed47f4d8`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 31890167 | 33915375 | 34565666 |
| `arithmetic-loop` | `aot_compile` | 5 | 205241542 | 212612083 | 216810125 |
| `arithmetic-loop` | `aot_run` | 5 | 3558666 | 3967250 | 4638542 |
| `array-mutation` | `interpreter` | 5 | 23727292 | 24247500 | 26486917 |
| `array-mutation` | `aot_compile` | 5 | 213597084 | 226433375 | 241498459 |
| `array-mutation` | `aot_run` | 5 | 3357125 | 3732792 | 4010583 |
| `closure-loop` | `interpreter` | 5 | 80790375 | 91560166 | 170262750 |
| `closure-loop` | `aot_compile` | 5 | 200936666 | 214073834 | 220594041 |
| `closure-loop` | `aot_run` | 5 | 3698542 | 3920334 | 4046583 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
