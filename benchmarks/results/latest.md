# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788224921214`
- git_commit: `e078c00ead45bda2597b3119c1466df1a2f1d4cd`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 29769667 | 30345500 | 30429334 |
| `arithmetic-loop` | `aot_compile` | 3 | 206003334 | 215162666 | 219819583 |
| `arithmetic-loop` | `aot_run` | 3 | 3649333 | 4054292 | 4311459 |
| `array-mutation` | `interpreter` | 3 | 25120500 | 25466958 | 31285459 |
| `array-mutation` | `aot_compile` | 3 | 208183417 | 211059166 | 214907708 |
| `array-mutation` | `aot_run` | 3 | 3817708 | 4038459 | 4147542 |
| `closure-loop` | `interpreter` | 3 | 76494208 | 76750041 | 77107500 |
| `closure-loop` | `aot_compile` | 3 | 211729959 | 214184500 | 236434000 |
| `closure-loop` | `aot_run` | 3 | 4236125 | 4975083 | 5190250 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
