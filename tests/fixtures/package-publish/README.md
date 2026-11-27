# 参照パッケージ publish→取得 E2E fixture（旧形式）

> **v1 での位置付け:** この fixture は旧形式の参照資料です。CI の
> `tools/check_package_publish_e2e.mjs` は `leftpad/` を旧 manifest の負例として
> 使い、旧 `package publish` が送信せずローカルで対象外を診断することだけを
> 検証します。旧 static PUT・PS01 registry・.npkg publish・npm 依存解決は
> v1 の対象外（P07/P11）であり、CI では公開しません。新 v1 の
> `package build → verify → ローカル実行` は同スクリプトが一時 project で行います。

`lnako package publish` でローカル fixture registry へ公開し、別 project から
`lock → sync → run --compat-js` で取得・実行できることを検証する旧 E2E 用の
参照パッケージ群（現在の CI では実行しません）。

| package | 構成 | E2E での役割 |
| --- | --- | --- |
| `leftpad/` | ESM plugin のみ（`[[exports]] esm`）。依存なし | consumer が registry 経由で取得して実行する plugin。公開には `compat-js = true` の profile が必要（E006 回避） |
| `greeting/` | source export + `[dependencies.pkg] leftpad`（public-id 指定） | registry の pkg→pkg 依存 edge と推移解決を検証 |
| `bundled/` | `[dependencies.path]`（payload 内 `packages/helper`） | path 依存を payload へ同梱する publish 側検証のみに使用。同梱 path 依存を持つ package の consumer sync は現行未対応のため取得しない |

npm 依存を持つ package の公開は現行契約で拒否される（static registry の
version record で表現できず、consumer の provider も npm を解決しないため
`E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY`）。E2E はこの拒否を失敗経路の
1 ケースとして固定する。plugin 実装内の npm bare import を含む取得 E2E は
`tests/fixtures/package-plugin-npm/`（`check_package_plugin_npm_e2e.mjs`）が
担当する。

`expected-stdout.txt` が consumer 側 `run --compat-js` の期待値。
`nako.lock` は registry の port が実行ごとに変わるため commit せず、E2E が
`lnako lock` で生成する。

fixture registry の `index.json` は server 側で静的に配信する。`leftpad` と
`greeting` の Public ID は fixture 固定値（`pkg:` + 32 hex）で、consumer の
`[dependencies.pkg]` が `public-id` でこれを参照する。実際の registry では
nako-registry 側の自動登録が id を発行するため、E2E は公開→取得の protocol
結合だけを検証する（#58 の gate 範囲）。
