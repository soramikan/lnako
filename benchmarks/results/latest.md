# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788090324314`
- git_commit: `ba9bd2f82e16483ef8eb1de68e471d09fd1c0518`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 35528750 | 37326541 | 39473041 |
| `arithmetic-loop` | `aot_compile` | 5 | 228509375 | 239007333 | 271905833 |
| `arithmetic-loop` | `aot_run` | 5 | 4375833 | 5715041 | 8621209 |
| `array-mutation` | `interpreter` | 5 | 26221458 | 28387875 | 29833875 |
| `array-mutation` | `aot_compile` | 5 | 235363750 | 274999834 | 286932375 |
| `array-mutation` | `aot_run` | 5 | 4224542 | 4951709 | 7005750 |
| `closure-loop` | `interpreter` | 5 | 84362166 | 106822958 | 111716458 |
| `closure-loop` | `aot_compile` | 5 | 243203875 | 287742292 | 323850959 |
| `closure-loop` | `aot_run` | 5 | 4681500 | 6072917 | 8488167 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
