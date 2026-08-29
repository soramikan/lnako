# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788045566473`
- git_commit: `8dcdaf713fb76de3636230cbbfcd421ad2bb04df`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `5`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 5 | 28968125 | 29252250 | 29538750 |
| `arithmetic-loop` | `aot_compile` | 5 | 206883041 | 208679250 | 213710542 |
| `arithmetic-loop` | `aot_run` | 5 | 4590834 | 5026291 | 5429834 |
| `array-mutation` | `interpreter` | 5 | 24177584 | 24221792 | 27495875 |
| `array-mutation` | `aot_compile` | 5 | 199324250 | 203797250 | 210079208 |
| `array-mutation` | `aot_run` | 5 | 3277583 | 3489333 | 3889750 |
| `closure-loop` | `interpreter` | 5 | 75104542 | 75241958 | 75606166 |
| `closure-loop` | `aot_compile` | 5 | 210495958 | 214689334 | 218125916 |
| `closure-loop` | `aot_run` | 5 | 5478875 | 6117125 | 9609791 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
