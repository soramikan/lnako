# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788097675182`
- git_commit: `dd36680b82fee8d47f589aecc716499d7f29081b`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 32297542 | 33098333 | 34738333 |
| `arithmetic-loop` | `aot_compile` | 5 | 217100709 | 222585667 | 223973417 |
| `arithmetic-loop` | `aot_run` | 5 | 4488834 | 5729916 | 8865375 |
| `array-mutation` | `interpreter` | 5 | 32021209 | 46574000 | 149448542 |
| `array-mutation` | `aot_compile` | 5 | 274645458 | 372029417 | 730518583 |
| `array-mutation` | `aot_run` | 5 | 7985541 | 11676041 | 41314625 |
| `closure-loop` | `interpreter` | 5 | 90102542 | 108675458 | 129357959 |
| `closure-loop` | `aot_compile` | 5 | 229671417 | 269623584 | 454842209 |
| `closure-loop` | `aot_run` | 5 | 4761625 | 4956917 | 5602667 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
