# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788433204347`
- git_commit: `9bc9637dcb2bb92b87ffa88b7879438fa29d51ae`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 23161500 | 23351667 | 23584750 |
| `arithmetic-loop` | `aot_compile` | 3 | 218852042 | 223670209 | 227141584 |
| `arithmetic-loop` | `aot_run` | 3 | 4268416 | 4514500 | 5310958 |
| `array-mutation` | `interpreter` | 3 | 6779500 | 6840166 | 7522583 |
| `array-mutation` | `aot_compile` | 3 | 220551250 | 227623041 | 297831583 |
| `array-mutation` | `aot_run` | 3 | 3822542 | 4153041 | 5910709 |
| `closure-loop` | `interpreter` | 3 | 43073542 | 45073250 | 45627166 |
| `closure-loop` | `aot_compile` | 3 | 230536500 | 234352417 | 237877375 |
| `closure-loop` | `aot_run` | 3 | 4431333 | 5302333 | 5605084 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
