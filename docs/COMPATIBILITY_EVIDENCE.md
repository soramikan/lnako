# 命令カタログ証拠レイヤー

`compat/v3.7.24/evidence.json`は、標準cnako 527 entryをカタログID単位で
既存fixtureへ関連付ける台帳です。実行結果やdispatch接続を証明する資料ではありません。
全entryの`executionEvidenceState`は現在`unverified`であり、将来の実行traceでのみ更新します。

## 生成と検証

```sh
node tools/sync_compat_evidence.mjs --generate
node tools/sync_compat_evidence.mjs --check
```

生成元は次の固定資料です。

- `compat/upstream.lock.json`（タグ、commit、命令カタログSHA-256の正本）
- `compat/v3.7.24/command_list.json`（公式全1,145命令）
- `compat/v3.7.24/matrix.json`（全命令の分類）
- `compat/v3.7.24/standard-cnako.json`（標準cnako 527 entry）
- `compat/v3.7.24/implemented.json`（実装台帳）
- `tests/oracle/*.json`（fixtureの明示`commands`と実在ID）

生成・検証時には、baselineとSHA-256を`upstream.lock.json`へ直接照合し、
standard各entryをmatrixの同一IDについて`name`、`plugin`、`status`など全共通フィールドで照合します。

## 関連付けの規則

fixtureのソース本文から命令名を推測することはしません。関連付けのoriginは次の二つだけです。

- `fixture.commands`: fixtureが明示した命令名
- `implemented.tests`: 実装台帳が記録し、`tests/oracle`に実在するfixture ID

`aotFixtureIds`は`native-cases.json`に実在するIDだけ、`compatJsFixtureIds`は
`compat-js-cases.json`に実在するIDだけを収録します。未解決の実装台帳IDは収録せず、
`unresolvedTestIds`へ残します。

`fixtureCoverageState`は実行成功を意味しません。

- `paired`: interpreterとAOTの明示fixtureがある
- `interpreter-only`: interpreterだけに明示fixtureがある
- `aot-only`: AOTだけに明示fixtureがある
- `none`: 明示fixtureがない
- `compat-js-only`: compat-js fixtureだけに明示関連付けがある

## 同名命令

同名異pluginの31組62 entryは`identityResolution: "ambiguous-name"`です。
同じfixtureへ命令名で割り当てられていても、命令名だけではcatalog IDやpluginを識別できず、
ID単位の実行証拠にはなりません。その理由は各entryへ明記され、実行証拠状態も`unverified`のままです。

## 実dispatch trace

`LNAKO_DISPATCH_TRACE`へ絶対JSONLパスを指定すると、InterpreterとAOTランタイムは
引数・値・ポインタを含まない固定メタデータだけを記録します。未指定時はファイルを作成せず、
標準出力、標準エラー、終了コードを変えません。既存ファイルは上書きせず、新しいパスだけを受理します。

- Interpreter: `callBuiltin`の完了を`dispatch-result`として記録し、`success`と`failure`を区別する
- AOT: builtin、切取、正規表現ABIへの到達を`dispatch-attempt`として記録する
- AOTの命令名: ソース上の別名ではなく、LLVM ABIへ渡ったcanonical opcode名
- 正常終了: 最終行に`trace-end`と`dropped: 0`を記録し、途中欠落を検出可能にする

書込み失敗と`runtime_deinit`を通らない異常終了はプログラム自体の意味を変えません。
その場合は`trace-end`が得られないため、検証ハーネスが実行基盤エラーとして拒否します。

`node tools/check_dispatch_trace.mjs`はtrace有無の実行結果一致、JSONL構造、
`切取`・`範囲切取`のInterpreter/AOT実dispatchを1 fixtureだけで検証します。
全527 entryのplugin・catalog ID、AOT成功結果、pre/post-opt IR、O0〜O3をまだ接続していないため、
このスモークテストだけで`executionEvidenceState`を更新してはいけません。
