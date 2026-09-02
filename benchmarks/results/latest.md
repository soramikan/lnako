# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788381731729`
- git_commit: `f753d320bad753e956f8706051efe7f10c0471ac`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 159909833 | 160607291 | 160904292 |
| `arithmetic-loop` | `aot_compile` | 3 | 206196583 | 208856625 | 352872208 |
| `arithmetic-loop` | `aot_run` | 3 | 3447458 | 3834542 | 3978375 |
| `array-mutation` | `interpreter` | 3 | 30260625 | 30310875 | 30570708 |
| `array-mutation` | `aot_compile` | 3 | 198881417 | 200091875 | 202479083 |
| `array-mutation` | `aot_run` | 3 | 3318041 | 3443916 | 3613833 |
| `closure-loop` | `interpreter` | 3 | 286357625 | 286537250 | 286723416 |
| `closure-loop` | `aot_compile` | 3 | 206051708 | 206908458 | 207460084 |
| `closure-loop` | `aot_run` | 3 | 3976000 | 4166375 | 4339667 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
