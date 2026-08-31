# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788166539138`
- git_commit: `b1dadae87ec51aac5540d257afb25268f12f63c2`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 29335417 | 29451875 | 29657208 |
| `arithmetic-loop` | `aot_compile` | 3 | 197070834 | 197989250 | 198287375 |
| `arithmetic-loop` | `aot_run` | 3 | 3379667 | 3501334 | 3923209 |
| `array-mutation` | `interpreter` | 3 | 23442458 | 23444042 | 23699125 |
| `array-mutation` | `aot_compile` | 3 | 197654750 | 197684916 | 198295833 |
| `array-mutation` | `aot_run` | 3 | 3190084 | 3315709 | 3805459 |
| `closure-loop` | `interpreter` | 3 | 72945042 | 73013709 | 75963125 |
| `closure-loop` | `aot_compile` | 3 | 192830709 | 199884458 | 206606917 |
| `closure-loop` | `aot_run` | 3 | 4071750 | 4250208 | 4383292 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
