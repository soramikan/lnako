# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788189150475`
- git_commit: `031a011b50b8275feca4239d12c92eee44cbf4dd`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 28809291 | 29328875 | 32175416 |
| `arithmetic-loop` | `aot_compile` | 3 | 196486792 | 197624750 | 198783084 |
| `arithmetic-loop` | `aot_run` | 3 | 5087083 | 6860834 | 9192750 |
| `array-mutation` | `interpreter` | 3 | 23326833 | 24007541 | 28164541 |
| `array-mutation` | `aot_compile` | 3 | 197355042 | 197800416 | 198326333 |
| `array-mutation` | `aot_run` | 3 | 3518666 | 5826791 | 8583334 |
| `closure-loop` | `interpreter` | 3 | 74516917 | 74575000 | 74646584 |
| `closure-loop` | `aot_compile` | 3 | 201570709 | 203452167 | 204855041 |
| `closure-loop` | `aot_run` | 3 | 4259791 | 6083459 | 6138459 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
