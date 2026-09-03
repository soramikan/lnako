# lnako benchmark

- schema: `1`
- generated_at_unix_ms: `1788422282562`
- git_commit: `a666e5ae3cf759d8c4928c1390c0055cb18f3329`
- target: `macos/aarch64`
- toolchain: Zig `0.16.0`, LLVM/LLD `22.1.8`
- suite_name: `lnako-core-v1`
- suite: `benchmarks/suite.json`
- optimization: `O2`
- iterations: `3`
- warmup: `1`

| case | mode | samples | min (ns) | median (ns) | max (ns) |
|---|---|---:|---:|---:|---:|
| `arithmetic-loop` | `interpreter` | 3 | 21913500 | 22010291 | 22238750 |
| `arithmetic-loop` | `aot_compile` | 3 | 195559875 | 197428083 | 198302208 |
| `arithmetic-loop` | `aot_run` | 3 | 3183166 | 3272292 | 3586625 |
| `array-mutation` | `interpreter` | 3 | 5351417 | 5452125 | 5539625 |
| `array-mutation` | `aot_compile` | 3 | 191343500 | 193868959 | 195695167 |
| `array-mutation` | `aot_run` | 3 | 3082875 | 3088208 | 3319958 |
| `closure-loop` | `interpreter` | 3 | 37887417 | 38084334 | 38298167 |
| `closure-loop` | `aot_compile` | 3 | 200031458 | 202043375 | 204211333 |
| `closure-loop` | `aot_run` | 3 | 3751667 | 3766625 | 4341291 |

測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。
