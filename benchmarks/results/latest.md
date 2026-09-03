# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788413477783`
- git_commit: `0c84863dbf28a4c9e2765dc7fda50488ddc8a21c`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 23378167 | 25665375 | 26711333 |
| `arithmetic-loop` | `aot_compile` | 3 | 199110041 | 200981750 | 213103458 |
| `arithmetic-loop` | `aot_run` | 3 | 4109875 | 4516250 | 4939250 |
| `array-mutation` | `interpreter` | 3 | 6985125 | 7209375 | 7505959 |
| `array-mutation` | `aot_compile` | 3 | 202037125 | 215605875 | 235475959 |
| `array-mutation` | `aot_run` | 3 | 4168750 | 5368709 | 5620333 |
| `closure-loop` | `interpreter` | 3 | 54322208 | 55365416 | 56108417 |
| `closure-loop` | `aot_compile` | 3 | 316494041 | 376040500 | 801203833 |
| `closure-loop` | `aot_run` | 3 | 7183875 | 7329208 | 7600125 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
