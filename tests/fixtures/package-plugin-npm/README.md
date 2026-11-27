# 参照 plugin+npm E2E fixture（旧形式）

> **v1 での位置付け:** この fixture は旧形式の参照資料です。CI の
> `tools/check_package_plugin_npm_e2e.mjs` は `app/` を旧 manifest の負例として
> 使い、読み替えずに拒否されることだけを検証します。旧 npm registry・npm 依存
> 解決・旧 lock の成功経路は v1 の対象外（P10/P11）であり、CI では実行しません。
> 新 v1 のローカル実行と `--compat-js` の言語検証は同スクリプトが一時 project で
> 行います。

`app/` は lnako のプロジェクトで、次の 2 つを同時に持ちます。

- `packages/leftpad`: ESM plugin（`[[exports]] esm = "plugin.mjs"`）。plugin 実装が
  npm ESM library `left-pad` を bare import し、`整形` 命令を登録する。
- `[dependencies.npm] left-pad`: 一般 npm ESM library。テストでは
  `registry/left-pad/` のソースを tar.gz 化し、127.0.0.1 の fixture registry
  から配信する（外部 network・npm CLI は使わない）。

`app/nako.toml` の `[profiles.compat]` は ESM-only 依存を `lnako lock` で解決
するために `compat-js = true` を宣言しています。依存 artifact は無条件の
JavaScript なので profile の os/cpu/abi は解決結果に影響しません。

旧形式での歴史的なフロー（現在の CI では実行しません）:

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

AOT は `--sbom <path>` で同梱 npm/ESM package の license 一覧（SPDX 2.3 風 JSON）も
出力できます。E2E は `.nako`・cache・`packages/`・`nako.toml` を退避した project 外 cwd で
生成物だけを実行し、bundled source だけで解決することを確認したうえで、SBOM に
`left-pad`（npm）と `leftpad`（path 依存 ESM plugin）の license が載ることを検査します。

## 検証範囲

`tools/check_package_plugin_npm_e2e.mjs` は Linux/macOS の compat CI job で、
`app/` の旧 manifest が `sync`・`run`・`package build` から移行診断で拒否され、
manifest を書き換えず旧 lock/環境も作らないことを確認します。続けて一時的な
v1 project で `run`（通常モード）と `run --compat-js` を実行し、v1 のローカル
実行と QuickJS の分離を確認します。旧 npm registry と npm tarball の E2E、AOT の
npm/ESM manifest 収録は v1 の対象外です。AOT と QuickJS の分離は
`tools/check_aot_quickjs_separation.mjs` が担当します。
