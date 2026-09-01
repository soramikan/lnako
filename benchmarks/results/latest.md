# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788283930823`
- git_commit: `79b28cf943ad6296c8902861c4cedd8a7675ad54`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 95720750 | 95935084 | 153391416 |
| `arithmetic-loop` | `aot_compile` | 3 | 199242750 | 204146875 | 205066084 |
| `arithmetic-loop` | `aot_run` | 3 | 3544791 | 3672250 | 4087584 |
| `array-mutation` | `interpreter` | 3 | 29920083 | 30071292 | 30128458 |
| `array-mutation` | `aot_compile` | 3 | 199007459 | 199262042 | 200477083 |
| `array-mutation` | `aot_run` | 3 | 3313666 | 3358875 | 3682166 |
| `closure-loop` | `interpreter` | 3 | 144400667 | 144586542 | 144613625 |
| `closure-loop` | `aot_compile` | 3 | 203654958 | 204243208 | 204646500 |
| `closure-loop` | `aot_run` | 3 | 3931084 | 3984083 | 4752583 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
