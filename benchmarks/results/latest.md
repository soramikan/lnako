# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788033372582`
- git_commit: `53621cafd55291ced88bc86fd0d2f85935ea38af`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 28952875 | 29087125 | 29442708 |
| `arithmetic-loop` | `aot_compile` | 5 | 202622041 | 205774125 | 206484333 |
| `arithmetic-loop` | `aot_run` | 5 | 3122708 | 3235125 | 6144334 |
| `array-mutation` | `interpreter` | 5 | 23740917 | 23979875 | 23998750 |
| `array-mutation` | `aot_compile` | 5 | 204883375 | 208252416 | 209594584 |
| `array-mutation` | `aot_run` | 5 | 2962417 | 3193542 | 5371875 |
| `closure-loop` | `interpreter` | 5 | 74081417 | 75581958 | 76066459 |
| `closure-loop` | `aot_compile` | 5 | 209737000 | 211573791 | 218142250 |
| `closure-loop` | `aot_run` | 5 | 3669083 | 3839833 | 4060209 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
