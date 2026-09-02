# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788387563950`
- git_commit: `fd53fd3094fa9426538114f0167ac6e0c2a222d5`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 21428625 | 21494417 | 21537458 |
| `arithmetic-loop` | `aot_compile` | 3 | 190871209 | 190946000 | 193874708 |
| `arithmetic-loop` | `aot_run` | 3 | 3499583 | 3800084 | 4186500 |
| `array-mutation` | `interpreter` | 3 | 6050959 | 6209750 | 6260958 |
| `array-mutation` | `aot_compile` | 3 | 187807333 | 196813000 | 199054125 |
| `array-mutation` | `aot_run` | 3 | 3052083 | 3060167 | 3746125 |
| `closure-loop` | `interpreter` | 3 | 38375375 | 38544125 | 38745708 |
| `closure-loop` | `aot_compile` | 3 | 192691709 | 193094375 | 193970125 |
| `closure-loop` | `aot_run` | 3 | 3840333 | 3888916 | 4273666 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
