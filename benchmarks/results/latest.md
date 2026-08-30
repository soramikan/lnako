# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788100856725`
- git_commit: `be46accd88edfa360f9c1518c74881fe270557c1`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 33016417 | 43387750 | 59694042 |
| `arithmetic-loop` | `aot_compile` | 5 | 263730459 | 334226375 | 589935375 |
| `arithmetic-loop` | `aot_run` | 5 | 7693333 | 9596334 | 11918958 |
| `array-mutation` | `interpreter` | 5 | 64241041 | 66685750 | 69229917 |
| `array-mutation` | `aot_compile` | 5 | 363534291 | 625014292 | 826587417 |
| `array-mutation` | `aot_run` | 5 | 4525959 | 5430042 | 13140375 |
| `closure-loop` | `interpreter` | 5 | 85130583 | 98006875 | 117993125 |
| `closure-loop` | `aot_compile` | 5 | 211942416 | 216056875 | 236351875 |
| `closure-loop` | `aot_run` | 5 | 4085208 | 4248917 | 4752584 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
