# lnako benchmark v2

`benchmarks/suites/v2.json` は、起動・コア実行・コレクション・数値計算・文字列・allocation・アプリケーション・シリアライズ・I/O・toolchain を分けて測る 20 ケースのスイートです。旧 `benchmarks/suite.json` と `benchmarks/comparison` の結果はこのスイートから参照しません。

保存済みの測定値は[ベンチマーク結果](../docs/benchmarks/RESULTS.md)を参照してください。全20ケースの結果をLinux・macOS・Windowsの個別文書にまとめています。

## ケースと固定 workload

各ケースの `expected_stdout` は、最終的な checksum まで含む完全一致の stdout です。`startup-empty` だけは空文字列を期待します。

| id | measurement | workload | expected stdout |
| --- | --- | --- | --- |
| `startup-empty` | `startup` | Nako 本体なし・出力なし | 空 |
| `startup-hello` | `startup` | `hello` を 1 回表示 | `hello` |
| `integer-arithmetic` | `steady_state` | seed `12345` の LCG を 100000 回 | `49913894` |
| `branch-mix` | `steady_state` | seed `19` の 3 分岐を 80000 回 | `58380` |
| `function-call` | `steady_state` | ユーザー関数を 90000 回 | `507772` |
| `closure-call` | `steady_state` | 捕捉値を使う closure を 60000 回 | `180000` |
| `recursion` | `steady_state` | Fibonacci(28) | `317811` |
| `nbody` | `steady_state` | 4 物体の積分を 600 step | `93200371` |
| `array-build` | `steady_state` | 数値を配列へ 60000 回追加 | `120000` |
| `array-scan` | `steady_state` | 55000 要素を添字で走査 | `27714168` |
| `hash-lookup` | `steady_state` | 動的キー 24000 件を登録・逆順 lookup | `288012000` |
| `string-concat` | `steady_state` | 不変文字列へ `ab` を 6000 回連結 | `12000` |
| `string-builder` | `steady_state` | 配列 append 後に 16000 要素を join | `32000` |
| `unicode-scan` | `steady_state` | 日本語・emoji 8 code point の列を 6000 回走査 | `54000` |
| `sieve` | `steady_state` | 上限 18000 のエラトステネスの篩 | `17409401` |
| `binary-trees` | `steady_state` | 深さ 11 の木を 3 回生成・走査 | `18393` |
| `word-count` | `steady_state` | 5 token の句を 3000 回分割・頻度集計 | `6333000` |
| `json-transform` | `steady_state` | 12 item の JSON を 300 回 parse/filter/serialize | `6048` |
| `file-read` | `steady_state` | 固定 fixture を読み込み全 code point を走査 | `756` |
| `compile-stress-medium` | `compile` | 150 個の逐次代入を含むソースをコンパイル | `157` |

`steady_state` のプログラムは、子プロセスの 1 回の起動内で上表の反復を行い、最後に小さな checksum だけを表示します。これにより、短い 1 回の kernel とプロセス起動時間が同じ値に埋もれにくくなります。`startup` はプロセス生成から終了までを測るため、この分離を保ったまま比較してください。`compile` はコンパイル時間を主対象にし、出力確認が必要な runner は実行確認を計測区間の外で行います。

`steady_state` も計測値はプロセス起動を含む wall-clock です。単一 child process の中でまとまった workload を実行するため、起動の相対的な影響を小さくできますが、純粋な関数 kernel の CPU 時間とは解釈しません。レポートの `timing_scope` は `process_batched_wall` として扱います。

## v2 schema

各 case は次のフィールドを持ちます。

- `id`, `category`, `kind`, `description`: 一意な名前、分類、処理の種類、測定意図。
- `measurement`: `startup`、`steady_state`、`compile` のいずれか。
- `profiles`: 利用するプロファイル。通常ケースは `smoke`、`normal`、`full`、コンパイル負荷ケースは `normal`、`full` です。
- `tags`: `integer`、`array`、`io` など、結果の集計や絞り込みに使う語。
- `source`: lnako と cnako が共有する Nako ソースへのパス。
- `sources`: `"same"` は `source` の共有を表します。Python/C/Rust は意味を揃えられるケースだけ明示パスを持ちます。
- `input.args`: runner がそのまま渡す文字列引数。空配列も有効です。
- `expected_stdout`: 出力の完全一致値。空文字列も有効です。

Nako の実行時引数は runtime ごとに argv の先頭が異なるため、入力を使う共通ソースは `コマンドライン` の最後の要素（seed/count の場合は最後から 2 番目と最後）を読みます。runner は interpreter には通常の実行オプションと `--` の後ろへ、AOT 実行ファイルには引数を直接渡してください。`file-read` の引数はリポジトリルートからの相対パスで、`benchmarks/fixtures/benchmark-input.txt` は読み取り専用の決定的な fixture です。

## 比較対象

Nadesiko 系の主比較は、同じ `source.nako3` を使う `lnako` と `cnako` です。Python/C/Rust の cross-language reference は、次の 3 ケースに限定しています。

- `integer-arithmetic`: 実行時 seed/count に依存する同一 LCG と checksum。
- `string-concat`: 毎回新しい文字列を作る copy-on-concat。C と Rust も旧値を新 buffer へコピーします。
- `string-builder`: Python の list/join、C の capacity buffer、Rust の `String::push_str`。Nako は配列 append と一括 join で、`string-concat` と異なる測定対象です。

`gonako` は v2 の case source に登録していません。suite の `runtime_support.gonako.supported` を `false` とし、runner のコマンドおよび argv 契約を検証できた時点で追加します。未登録の runtime を、Nako 系の主比較から失敗値として扱わないでください。

## 実行

native runner の smoke 実行は次の通りです。

```sh
zig-out/bin/lnako benchmark --suite benchmarks/suites/v2.json --profile smoke
```

`--profile normal` は通常の記録、`--profile full` はリリース前の確認に使います。`--case integer-arithmetic` のように case を絞り、`--optimization O0`〜`O3` で AOT 条件を指定できます。native runner は v2 の `sources` にある `"same"` を共通 `source` の別名として解決します。

cross-language comparison は比較 runner から実行します。

```sh
.cache/toolchains/node-24.15.0/bin/node tools/run_comparison_benchmark.mjs \
  --suite benchmarks/suites/v2.json --profile smoke \
  --runtimes lnako,cnako,python,c,rust
```

各 runtime の実行ファイルが PATH にない場合は `--lnako`、`--cnako`、`--python`、`--clang`、`--rustc` または対応する `LNAKO_BENCHMARK_*` 環境変数で指定します。通常の比較結果は環境依存のため作業ツリーへ固定しません。CI artifact や再現可能な compiler 実験の証拠として JSON/Markdown を意図的に保存する場合は、その workflow が指定する出力先・commit provenance・toolchain metadata と一緒に扱います。

## 解釈上の注意

- `startup` は起動・解析・runtime 初期化・stdout・終了を含む wall-clock 値です。
- `steady_state` は起動後に bounded な反復を実行しますが、現状の出力は最終 checksum だけです。少数 sample の値をリリース性能値とみなさず、profile の sample 数とばらつきも併記してください。
- `string-concat` と `string-builder` は同じランキングに混ぜません。前者は immutable copy、後者は各言語の自然な可変構築です。
- `file-read` は OS の page cache と filesystem の影響を受けるため、CPU kernel の category スコアへ合算しません。
- `binary-trees` は演算速度より辞書 object の生成・保持・走査を測ります。GC や allocator の実装差を含む値です。
- `compile-stress-medium` は代表的な中規模ソースの compile growth を見るための負荷で、runtime の定常実行値と比較しません。

v2 の JSON とケースソースは、固定 Node 24.15.0 の公式 `cnako3.mjs` と lnako interpreter/AOT の出力が一致することを確認してから runner へ渡します。測定結果の永続化は、通常の machine benchmark と、履歴比較・compiler 実験の evidence として保存するものを区別してください。
