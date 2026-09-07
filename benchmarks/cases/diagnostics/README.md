# 診断用microbenchmark suite

`../../suites/diagnostics.json` は、M8〜M15の最適化で差が現れる実行経路を分離して見るための12ケースです。`cnako3` と `lnako run` は各ケースの同じ `.nako3` source、同じruntime input、同じ固定stdoutを使います。既存の20ケースsuiteや保存済みresultsには追加しません。

各ケースは1回の子プロセスでまとまった反復を実行します。runnerの実行測定値はプロセス生成、runtime初期化、workload、stdout、終了までを含む `process_batched_wall` です。Interpreterとcnakoにはsource parseも含まれ、AOT実行には含まれません。setupを計測区間から除いた値として扱わず、固定サイズの配列・dictionary構築や長寿命rootの構築も含めて比較します。反復回数は短いkernelの起動ノイズを相対的に下げるために設定していますが、純粋な関数kernelのCPU時間ではありません。

| case | 固定input | stdout | 診断対象 |
| --- | ---: | ---: | --- |
| `local-load-store` | 100000 | `300000` | 関数内localのload/store |
| `global-load-store` | 100000 | `300000` | module globalのload/store |
| `direct-call-empty` | 100000 | `700000` | captureなし引数なし直接call |
| `captured-call-empty` | 100000 | `700000` | 1値を捕捉した引数なしclosure call |
| `array-read-only` | 64000 | `2080000` | 固定配列のindexed read |
| `array-write-only` | 64000 | `2080` | 固定配列のindexed write |
| `dict-small` | 100000 | `100000` | 4 entry dictionaryのread/write |
| `dict-large-read` | 64000 | `8224000` | 256 entry dictionaryのread |
| `string-copy-fixed` | 100000 | `1000000` | 長さ固定のimmutable copy-on-concat |
| `gc-short-lived` | 4000 | `8006000` | 反復ごとに破棄可能になる配列allocation |
| `gc-long-lived` | 2000 | `2001000` | nested arrayを保持したGC root走査 |
| `numeric-function-call` | 50000 | `6250275000` | 2引数numeric function call |

`array-read-only` と `array-write-only` は64要素の構築を先に行い、diagnostic対象の反復ではそれぞれreadまたはwriteを行います。`dict-large-read` は256個のkey文字列をsetup時に作り、read反復内でkey文字列を連結しないようにして文字列連結の費用をread反復から外しています。read反復にはdictionary lookupとkey配列へのアクセスが含まれます。`string-copy-fixed` は毎回10 UTF-16 code unitの新しい文字列を作り、長くなるconcatと比較しません。`gc-short-lived` は直前の配列を上書きし、`gc-long-lived` は全nested arrayを保持してから走査します。

## 出力確認と測定

公式処理系とInterpreterのstdout確認は、リポジトリルートで次のように行えます。公式cnakoの実行パスは環境に合わせて置き換えてください。

```sh
CNako=/path/to/cnako3
lnako=zig-out/bin/lnako
src=benchmarks/cases/diagnostics/local-load-store/source.nako3
"$CNako" "$src" 100000
"$lnako" run "$src" -- 100000
```

12ケースを正式に測る場合は、結果を既存resultsへ書かない一時出力先を指定します。

```sh
zig-out/bin/lnako benchmark \
  --suite benchmarks/suites/diagnostics.json \
  --profile smoke \
  --output /private/tmp/lnako-diagnostics.json \
  --markdown /private/tmp/lnako-diagnostics.md
```

このrunnerは各ケースで`interpreter`、`aot_compile`、`aot_run`を順に測定します。`aot_compile`の出力確認は計測外で行われ、`aot_run`は生成物を同じruntime inputで実行してstdoutを確認します。`cnako3`とのstdout確認は比較runnerで行い、AOT O2が利用できない環境ではそのruntime/modeを未測定として残します。
