# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788403277665`
- git_commit: `a78514f3146c8bc4e2f153efbaad9958bfea4c7a`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 157867458 | 158094292 | 159385084 |
| `arithmetic-loop` | `aot_compile` | 3 | 206915500 | 208001000 | 209533250 |
| `arithmetic-loop` | `aot_run` | 3 | 3323583 | 3387167 | 3892250 |
| `array-mutation` | `interpreter` | 3 | 29834416 | 29970667 | 30009167 |
| `array-mutation` | `aot_compile` | 3 | 203175125 | 206255250 | 212859916 |
| `array-mutation` | `aot_run` | 3 | 3161292 | 3190916 | 3780917 |
| `closure-loop` | `interpreter` | 3 | 282057375 | 286083083 | 287404875 |
| `closure-loop` | `aot_compile` | 3 | 209539750 | 215543416 | 219383125 |
| `closure-loop` | `aot_run` | 3 | 3798000 | 3891916 | 4119041 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
