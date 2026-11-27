# package-common — cnako/lnako 共通 package import fixture（v1）

Issue #210（#50 の残ゲート）の共通fixture。同じ `.nako3` ソースを lnako と
公式 cnako3 v3.7.24 の両方で実行し、`パッケージ:` / `pkg:` 取り込みの
alias・subpath・exports 境界と、package scope の alias 分離を固定する。

パッケージ形式は仕様 v1 だけを使う。旧 `[package].name`、`[[exports]]`、
`[dependencies.path]`、旧 `.npkg`、旧 lock は使わない。lnako 側は
`lnako package build` で `.npkg` を作り、script が実 SHA-256 とサイズから
静的ローカル index を組み立て、`lnako sync --v1-fixture` で解決する。
公式 cnako3 側は v1 で materialize された package source を、テスト用
adapter `tools/lib/package/cnako_package_loader.mjs` 経由で実行する。

## 構成

```
app/
  nako.toml                    # v1 local project。demo/util への [dependencies]
  main.nako3                   # 共通fixtureの入口（両処理系で同じソース）
packages/demo/
  nako.toml                    # exports: ".", "./calc", "./preview"
  src/demo.nako3               # package内部の相対取り込み + 関数 + 変数
  src/helper.nako3             # package境界の内側にある相対import先
  src/demo__calc.nako3         # subpath "./calc" の export
  src/demo__preview.nako3      # subpath "./preview" の export
packages/util/
  nako.toml
  src/util.nako3
reject-undeclared/               # root scopeに未宣言のalias
reject-private-subpath/        # 宣言されていないsubpath（非公開入口）
reject-version-specifier/      # `パッケージ:demo@1.0.0` のversion指定
reject-scope-alias/            # package scopeに未宣言のalias（root aliasを継承しない）
reject-symlink-escape/         # package treeの外を指すsymlink entry（packで拒否）
expected-stdout.txt            # 受理系の期待stdout（両処理系で同一）
```

`packages/demo` と `packages/util` が静的 index に載る。`reject-scope-alias`
だけは専用の `demo`（`@example/scope-demo`）を持ち、package scopeから
root の `util` が見えないことを固定する。

## 実行方法

比較スクリプト（lnako Interpreter + 公式cnako3 の両方を実行して比較）:

```sh
node tools/compare_package_import_oracle.mjs \
  --oracle /path/to/nadesiko3-3.7.24
# CIではビルド済みのため --no-build を付ける
```

script は fixture を一時ディレクトリへ複製し、次の順で v1 環境を作る。

1. `lnako package build <package source> -o <artifact>` で `.npkg` を生成
2. 実バイト列の SHA-256/サイズから `index/v1/config.json` と
   `index/v1/packages/<scope>/<name>.json` を書き、`.npkg` を
   `urls/cdn.example.invalid/artifacts/` へ置く
3. `lnako sync --v1-fixture <fixture> --registry https://registry.example.invalid`
4. `lnako run --no-sync main.nako3`

比較スクリプトは受理系について、`lnako` / 公式cnako3 / 公式cnako3
`--no-sync` の3経路のstdout一致、委譲loaderがfixtureソースを書き換えないこと
（ツリー全体のsha256比較）、`nako.lock` を改変した `--no-sync` が
`E034_INVALID_ENVIRONMENT_REFERENCE` で拒否されることを検査する。

lnako 単独（作業ディレクトリは `app/`）:

```sh
cd tests/fixtures/package-common/app
lnako sync --v1-fixture /path/to/prepared-fixture \
  --registry https://registry.example.invalid
lnako run --no-sync main.nako3
```

公式 cnako3 単独（委譲loader経由）:

```sh
cd tests/fixtures/package-common/app
node ../../../../tools/lib/package/cnako_package_loader.mjs \
  --root . --entry main.nako3 \
  --oracle /path/to/nadesiko3-3.7.24 \
  --lnako ../../../../zig-out/bin/lnako \
  --v1-fixture /path/to/prepared-fixture \
  --registry https://registry.example.invalid
# 準備済み環境の単独検証（lnakoを起動しない）は --no-sync
```

`--v1-fixture` の実体は script が一時ディレクトリに作る。手元で同じ構成を
作る場合は `tools/lib/package/v1_static_fixture.mjs` の
`buildArtifact` / `writeStaticIndex` を使う。

## 期待stdout

`expected-stdout.txt` の11行。`デモ` / `計算` / `プレビュー` / `道具` の
呼び出しと、package export の変数 `デモ値` の参照を含む。`demo-init` /
`calc-init` / `util-init` が1回ずつ出ることで、同じexportを `パッケージ:` と
`pkg:` の両表記で取り込んでもmoduleの初期化が一度だけであることを固定する。

## 境界ケース

| fixture | 内容 | lnako | cnako（委譲loader） |
|---------|------|-------|----------------------|
| `app` | alias（`パッケージ:`/`pkg:`）、subpath（`calc`）、subpath（`preview`）、package内部の相対import、変数・関数引数 | 受理 | 受理 |
| `reject-undeclared` | root scopeに無いalias | `error[invalid_import]` | `E013_MISSING_PACKAGE` |
| `reject-private-subpath` | exportに無いsubpath | `error[invalid_import]` | `E013_MISSING_PACKAGE` |
| `reject-version-specifier` | `パッケージ:demo@1.0.0` | `error[invalid_import]` | `E013_MISSING_PACKAGE` |
| `reject-scope-alias` | package scopeからroot直下のaliasを参照 | `error[invalid_import]` | `E013_MISSING_PACKAGE` |
| `reject-symlink-escape` | package tree外を指すsymlink entry | `SymlinkNotAllowed`（pack） | 対象外（v1 ZIPはsymlinkを収録できない） |

拒否系は「両処理系が拒否すること」を検査し、診断文言の一致は要求しない。
`reject-symlink-escape` の symlink はリポジトリへコミットせず、比較
スクリプトが作業コピー内に作成する。v1 では `.npkg` に symlink を収録
できないため、この1件は `lnako package build` の拒否として検査する。
symlinkを作成できない環境ではこのケースだけskipし、理由をログへ出す。

## namespace の整合ルール

lnako は取り込み alias から公開 namespace を作る（`パッケージ:demo` →
`demo__`、`パッケージ:demo/calc` → `demo__calc__`）。公式 cnako3 は取り込んだ
ファイルの basename から namespace を作るため、共通fixtureでは export の
`entry` の basename を namespace と一致させている
（`src/demo.nako3`, `src/demo__calc.nako3`, `src/demo__preview.nako3`）。
同じexportを `name` と `alias` の両方のsubpathで取り込むと、lnako の
namespace が入力したsubpath文字列で変わる一方 cnako は basename 固定なので
一致しない。v1 には export alias が無いため、共通fixtureは subpath だけを
使う。

## 公式cnako3 v3.7.24 の制約と #61 ゲート

公式 cnako3 v3.7.24 は `パッケージ:` 構文を持たない。このfixtureの cnako 側は、
仕様 `docs/package-system/SPECIFICATION.md` §7.3 の委譲契約
（依存解決・同期は `lnako sync`、cnako は v1 environment の package/export
対応だけを使う）を `tools/lib/package/cnako_package_loader.mjs` で接続している。

この loader は **テスト用adapter** であり、cnako本体への実装（#61）ではない。
fixtureソースは書き換えず、公式 cnako3 の `resolvePath` だけを差し替える。
構文解析・名前空間・実行は公式 cnako3 が行う。cnako本体への実装と上流
公開リリースでの受理は #61 / #210 の上流ゲートとして残る。

adapterの制限（#61の実装範囲）:

- v1 environment の package は materialize 済み世代 dir
  （`.nako/v1/generations/<gen>/packages/<sha256>`）を参照する。
- export の選択は v1 environment の `exports[].subpath` を name に写し、
  lnako 本体と同じ既定export選択（`main`/`index` 名 → basename → 単一export）
  を実装する。
- 実行できるのは source export（`.nako3`）だけ。ESM/native artifact や
  `.nako3` 以外の拡張子は `E031_UNSUPPORTED_RUNTIME` で明示的に拒否する。
- package所有sourceからの相対・絶対取り込みは、lnako の module graph と同じく
  package境界の内側だけを許可する（境界外は `E029_INVALID_VALUE`）。
- `--no-sync` が検証するのは v1 environment の `lock_sha256`（`sha256:<hex>`・
  生hex・SRI の3形式）、世代・profile・runtime、`.nako/v1` の managed path
  成分のsymlink検査のみ。profile・命令メタデータ・lockグラフの完全一致は
  #61 の範囲。
- 取り込み元の依存scopeは package path の包含（最長一致）で近似する。
  lnako 本体は edge 由来の owner を優先するため、入れ子の mutable path 依存で
  owner が包含関係と食い違う構成は #61 の実装範囲。

## 検証範囲外

- lnako AOT O0〜O3 の生成物実行は `tests/fixtures/package-aot` と
  `tools/compare_package_import_aot_oracle.mjs`（#209）が担当する。
- 実レジストリ・実ネットワーク・公開 API は対象外。index はテスト用の
  静的 fixturedir だけで、`--v1-fixture` の解決規則は
  `src/package/v1_client_fixture.zig` に従う。
