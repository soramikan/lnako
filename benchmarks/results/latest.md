# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788372374626`
- git_commit: `7bed0d9b48ac2bb01a94d68160111f011ac5b615`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 172620583 | 174945459 | 181604458 |
| `arithmetic-loop` | `aot_compile` | 3 | 215867375 | 238773709 | 240016625 |
| `arithmetic-loop` | `aot_run` | 3 | 3780041 | 3832958 | 4149500 |
| `array-mutation` | `interpreter` | 3 | 31132500 | 31145542 | 31295292 |
| `array-mutation` | `aot_compile` | 3 | 211684041 | 221343333 | 243910875 |
| `array-mutation` | `aot_run` | 3 | 3279500 | 3328375 | 3668458 |
| `closure-loop` | `interpreter` | 3 | 285026333 | 288727708 | 288758000 |
| `closure-loop` | `aot_compile` | 3 | 212254750 | 215908208 | 224766250 |
| `closure-loop` | `aot_run` | 3 | 3901042 | 4253417 | 4451500 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
