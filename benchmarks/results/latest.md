# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788128255130`
- git_commit: `45639e82d033048f492edb860bb1d7540aa2b006`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 28759792 | 28869208 | 29010708 |
| `arithmetic-loop` | `aot_compile` | 5 | 194731042 | 196462042 | 197094459 |
| `arithmetic-loop` | `aot_run` | 5 | 3152458 | 3245084 | 3599667 |
| `array-mutation` | `interpreter` | 5 | 23382500 | 23622917 | 23705417 |
| `array-mutation` | `aot_compile` | 5 | 197907375 | 204214375 | 206305125 |
| `array-mutation` | `aot_run` | 5 | 2996834 | 3114875 | 3689000 |
| `closure-loop` | `interpreter` | 5 | 76441416 | 76846750 | 77116042 |
| `closure-loop` | `aot_compile` | 5 | 203852041 | 211388375 | 217925041 |
| `closure-loop` | `aot_run` | 5 | 4294000 | 4743167 | 10761375 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
