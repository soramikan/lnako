# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1787915767678`
- git_commit: `5a83e73d9ee56bcdcf7796585e447586489338a2`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 30716167 | 31189542 | 41224666 |
| `arithmetic-loop` | `aot_compile` | 5 | 203820709 | 208390958 | 239504875 |
| `arithmetic-loop` | `aot_run` | 5 | 3694375 | 4045542 | 4902667 |
| `array-mutation` | `interpreter` | 5 | 24525625 | 25310458 | 29159417 |
| `array-mutation` | `aot_compile` | 5 | 204411375 | 208702458 | 216309584 |
| `array-mutation` | `aot_run` | 5 | 4134416 | 4419750 | 5013416 |
| `closure-loop` | `interpreter` | 5 | 76928708 | 77407625 | 78804166 |
| `closure-loop` | `aot_compile` | 5 | 210688917 | 213699333 | 220282708 |
| `closure-loop` | `aot_run` | 5 | 4838334 | 5163792 | 5717458 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
