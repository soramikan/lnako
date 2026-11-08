# 参照 plugin+npm E2E fixture

`app/` は lnako のプロジェクトで、次の 2 つを同時に持ちます。

- `packages/leftpad`: ESM plugin（`[[exports]] esm = "plugin.mjs"`）。plugin 実装が
  npm ESM library `left-pad` を bare import し、`整形` 命令を登録する。
- `[dependencies.npm] left-pad`: 一般 npm ESM library。テストでは
  `registry/left-pad/` のソースを tar.gz 化し、127.0.0.1 の fixture registry
  から配信する（外部 network・npm CLI は使わない）。

`app/nako.toml` の `[profiles.compat]` は ESM-only 依存を `lnako lock` で解決
するために `compat-js = true` を宣言しています。依存 artifact は無条件の
JavaScript なので profile の os/cpu/abi は解決結果に影響しません。

想定フロー:

```sh
LNAKO_NPM_REGISTRY=http://127.0.0.1:<port> lnako lock --package-cache-dir <cache>
lnako sync --offline --package-cache-dir <cache>
lnako run main.nako3 --compat-js
```

`expected-stdout.txt` が実行結果の期待値です。`nako.lock` は fixture registry の
port が実行ごとに変わるため commit せず、E2E の `lnako lock` で生成します。

`aot-main.nako3` は AOT（`--compat-js --backend aot`）用の entry です。ESM plugin
命令の AOT dispatch は follow-up のため、同じ project のまま npm bare import を
`JS実行` から解決し、AOT runtime の npm resolver と ESM manifest 収録を確認します
（`expected-aot-stdout.txt` が期待値）。

## 検証範囲

`tools/check_package_plugin_npm_e2e.mjs` は Linux/macOS の compat CI job で実バイナリの
`lock → sync --offline → run --compat-js --offline` を実行します。Windows は AOT が
対象外のため、同じ fixture を in-process の Zig テスト（`-Dcompat-js=true` の
compat-aot test step）で検証します（lock/sync/run と通常モード拒否、AOT は含まない）。
