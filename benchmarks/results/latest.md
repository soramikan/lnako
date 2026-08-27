# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1787823027241`
- git_commit: `63d9c2b38dc5b589e4190fc1f039b758a361a863`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 29577041 | 29878125 | 29922375 |
| `arithmetic-loop` | `aot_compile` | 5 | 184233167 | 185352375 | 186337666 |
| `arithmetic-loop` | `aot_run` | 5 | 3109083 | 3398000 | 3976750 |
| `array-mutation` | `interpreter` | 5 | 23643416 | 23795250 | 24195000 |
| `array-mutation` | `aot_compile` | 5 | 186012084 | 187539208 | 188129125 |
| `array-mutation` | `aot_run` | 5 | 3114500 | 3239000 | 3674666 |
| `closure-loop` | `interpreter` | 5 | 77187875 | 77574416 | 77940125 |
| `closure-loop` | `aot_compile` | 5 | 191724833 | 193756708 | 194322875 |
| `closure-loop` | `aot_run` | 5 | 3702708 | 3870166 | 4139250 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
