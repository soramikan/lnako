# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788109057735`
- git_commit: `df3b5b2592e5a09950c9246918d12130da87d335`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 29077042 | 29288625 | 29637750 |
| `arithmetic-loop` | `aot_compile` | 5 | 194185084 | 196268625 | 197122250 |
| `arithmetic-loop` | `aot_run` | 5 | 3154333 | 3429958 | 3847792 |
| `array-mutation` | `interpreter` | 5 | 23552958 | 23652000 | 23689792 |
| `array-mutation` | `aot_compile` | 5 | 195780916 | 197303416 | 198676458 |
| `array-mutation` | `aot_run` | 5 | 3044209 | 3077750 | 3220125 |
| `closure-loop` | `interpreter` | 5 | 76954083 | 77185458 | 77498875 |
| `closure-loop` | `aot_compile` | 5 | 201250042 | 202613958 | 202865417 |
| `closure-loop` | `aot_run` | 5 | 3673209 | 3808167 | 4054416 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
