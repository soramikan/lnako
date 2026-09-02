# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788392668789`
- git_commit: `7aa28782b500d10b8a02f00015da90562e663369`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 157520792 | 158103667 | 159411583 |
| `arithmetic-loop` | `aot_compile` | 3 | 116345708 | 117457000 | 118703250 |
| `arithmetic-loop` | `aot_run` | 3 | 3380167 | 3480208 | 4092167 |
| `array-mutation` | `interpreter` | 3 | 30377000 | 30562792 | 30573959 |
| `array-mutation` | `aot_compile` | 3 | 119061416 | 120638417 | 131699500 |
| `array-mutation` | `aot_run` | 3 | 3406458 | 3425375 | 4610458 |
| `closure-loop` | `interpreter` | 3 | 286348417 | 286514208 | 286753375 |
| `closure-loop` | `aot_compile` | 3 | 126591375 | 127441917 | 127907875 |
| `closure-loop` | `aot_run` | 3 | 4036709 | 4115084 | 4582833 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
