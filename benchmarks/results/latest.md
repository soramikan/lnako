# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788010623964`
- git_commit: `09d72347ce19ed7cbf0c08077a2e8028df06d93a`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 29674750 | 30163916 | 30241209 |
| `arithmetic-loop` | `aot_compile` | 5 | 189595833 | 193621083 | 200374292 |
| `arithmetic-loop` | `aot_run` | 5 | 3254833 | 3468084 | 3935791 |
| `array-mutation` | `interpreter` | 5 | 23511708 | 23943584 | 24195750 |
| `array-mutation` | `aot_compile` | 5 | 198989750 | 204151333 | 207209833 |
| `array-mutation` | `aot_run` | 5 | 3091209 | 3148584 | 3558792 |
| `closure-loop` | `interpreter` | 5 | 76792208 | 77382834 | 78002500 |
| `closure-loop` | `aot_compile` | 5 | 204989625 | 205852708 | 208766041 |
| `closure-loop` | `aot_run` | 5 | 3775500 | 3883000 | 4283500 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
