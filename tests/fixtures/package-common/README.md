# package-common — cnako/lnako 共通 package import fixture

Issue #210（#50 の残ゲート）の共通fixture。同じ `.nako3` ソースを lnako と
公式 cnako3 v3.7.24 の両方で実行し、`パッケージ:` / `pkg:` 取り込みの
alias・subpath・exports 境界と、package scope の alias 分離を固定する。
パッケージはリポジトリ内の path 依存だけを使い、外部ネットワークへ出ない。

## 構成

```
app/
  nako.toml                    # root。demo/util への [dependencies.path]
  main.nako3                   # 共通fixtureの入口（両処理系で同じソース）
  demo/nako.toml               # exports: main / calc / extra(alias=preview)
  demo/src/demo.nako3          # package内部の相対取り込み + 関数 + 変数
  demo/src/helper.nako3        # package境界の内側にある相対import先
  demo/src/demo__calc.nako3    # subpath `calc` のexport
  demo/src/demo__preview.nako3 # export alias `preview` のsubpath `preview`
  util/nako.toml               # root直下の別パッケージ
  util/src/util.nako3
expected-stdout.txt            # 受理系の期待stdout（両処理系で同一）
reject-undeclared/             # root scopeに未宣言のalias
reject-private-subpath/        # 宣言されていないsubpath（非公開入口）
reject-version-specifier/      # `パッケージ:demo@1.0.0` のversion指定
reject-scope-alias/            # package scopeに未宣言のalias（root aliasを継承しない）
reject-symlink-escape/         # package treeの外を指すsymlink entry
```

manifest の path 依存は現行 schema の `[dependencies.path]` で宣言する
（`[packages]` というテーブルは schema v1 に存在しない）。

## 実行方法

比較スクリプト（lnako Interpreter + 公式cnako3 の両方を実行して比較）:

```sh
node tools/compare_package_import_oracle.mjs \
  --oracle /path/to/nadesiko3-3.7.24
# CIではビルド済みのため --no-build を付ける
```

lnako 単独（作業ディレクトリは `app/`）:

```sh
cd tests/fixtures/package-common/app
../../../../zig-out/bin/lnako run main.nako3
```

公式 cnako3 単独（委譲loader経由）:

```sh
cd tests/fixtures/package-common/app
node ../../../../tools/lib/package/cnako_package_loader.mjs \
  --root . --entry main.nako3 \
  --oracle /path/to/nadesiko3-3.7.24 \
  --lnako ../../../../zig-out/bin/lnako
# 準備済み環境の単独検証（lnakoを起動しない）は --no-sync
```

比較スクリプトはfixtureを一時ディレクトリへ複製してから実行する。
上のスニペットのように `app/` で直接 `lnako run` した場合は `.nako/` と
`nako.lock` がfixture内に残るが、`.gitignore` で除外される。比較スクリプトは
受理系について、`lnako` / 公式cnako3 / 公式cnako3 `--no-sync` の3経路の
stdout一致、委譲loaderがfixtureソースを書き換えないこと（ツリー全体の
sha256比較）、`nako.lock` を改変した `--no-sync` が
`E034_INVALID_ENVIRONMENT_REFERENCE` で拒否されることを検査する。

## 期待stdout

委譲loaderの境界（既定exportのフォールバック・alias衝突・規範path・拡張子・
`--no-sync` のlock照合）は `node --test tools/cnako_package_loader_test.mjs` で
単体検証する（CIのPackage manifest tool testsで実行）。

`expected-stdout.txt` の11行。`デモ` / `計算` / `プレビュー` / `道具` の
呼び出しと、package export の変数 `デモ値` の参照を含む。`demo-init` /
`calc-init` / `util-init` が1回ずつ出ることで、同じexportを `パッケージ:` と
`pkg:` の両表記で取り込んでもmoduleの初期化が一度だけであることを固定する。

## 境界ケース

| fixture | 内容 | lnako | cnako（委譲loader） |
|---------|------|-------|----------------------|
| `app` | alias（`パッケージ:`/`pkg:`）、subpath（`calc`）、export alias subpath（`preview`）、package内部の相対import、変数・関数引数 | 受理 | 受理 |
| `reject-undeclared` | root scopeに無いalias | `error[invalid_import]` | `E013_MISSING_PACKAGE` |
| `reject-private-subpath` | exportに無いsubpath | `error[invalid_import]` | `E013_MISSING_PACKAGE` |
| `reject-version-specifier` | `パッケージ:demo@1.0.0` | `error[invalid_import]` | `E013_MISSING_PACKAGE` |
| `reject-scope-alias` | package scopeからroot直下のaliasを参照 | `error[invalid_import]` | `E013_MISSING_PACKAGE` |
| `reject-symlink-escape` | package tree外を指すsymlink entry | `E029_INVALID_VALUE` | `E029_INVALID_VALUE`（lnako syncの拒否を委譲） |

拒否系は「両処理系が拒否すること」を検査し、診断文言の一致は要求しない。
`reject-symlink-escape` の symlink はリポジトリへコミットせず、比較
スクリプトが作業コピー内に作成する（Windowsのcheckout設定に依存させない）。
symlinkを作成できない環境ではこのケースだけskipし、理由をログへ出す。

## namespace の整合ルール

lnako は取り込み alias から公開 namespace を作る（`パッケージ:demo` →
`demo__`、`パッケージ:demo/calc` → `demo__calc__`）。公式 cnako3 は取り込んだ
ファイルの basename から namespace を作るため、共通fixtureでは export の
`path` の basename を namespace と一致させている
（`src/demo.nako3`, `src/demo__calc.nako3`, `src/demo__preview.nako3`）。
同じexportを `name` と `alias` の両方のsubpathで取り込むと、lnako の
namespace が入力したsubpath文字列で変わる一方 cnako は basename 固定なので
一致しない。共通fixtureはこの制約を避けるため、export alias 側のsubpathだけを
使う。cnako 側の namespace 導出を alias 基準へ寄せるのは #61 の範囲。
なお同一の物理ファイルを `パッケージ:` と相対pathの双方で取り込むと、cnako は
filePath で dedup して初期化1回、lnako は owner 付き identity で分離する（§7.2）。
fixtureを拡張するときはこの差を前提にする。

## 公式cnako3 v3.7.24 の制約と #61 ゲート

公式 cnako3 v3.7.24 は `パッケージ:` 構文を持たない。このfixtureの cnako 側は、
仕様 `docs/package-system/SPECIFICATION.md` §7.3 の委譲契約
（依存解決・同期は `lnako sync --json`、cnako は `.nako/environment.json` の
alias → package key 対応だけを使う）を
`tools/lib/package/cnako_package_loader.mjs` で接続している。

この loader は **テスト用adapter** であり、cnako本体への実装（#61）ではない。
fixtureソースは書き換えず、公式 cnako3 の `resolvePath` だけを差し替える。
構文解析・名前空間・実行は公式 cnako3 が行う。cnako本体への実装と上流
公開リリースでの受理は #61 / #210 の上流ゲートとして残る。

adapterの制限（#61の実装範囲）:

- 既定exportの選択は lnako 本体と同じ3段フォールバック（`name` main/index →
  path basename `main.nako3`/`index.nako3` → exports 1件）を実装する。
- 実行できるのは source export（`.nako3`）だけ。ESM/native artifact や
  `.nako3` 以外の拡張子は `E031_UNSUPPORTED_RUNTIME` で明示的に拒否する。
- package所有sourceからの相対・絶対取り込みは、lnako の module graph と同じく
  package境界の内側だけを許可する（境界外は `E029_INVALID_VALUE`）。
- `--no-sync` が検証するのは `lockSha256`（`sha256:<hex>`・生hex・SRI の
  3形式）、環境recordの形状・alias衝突、`.nako` を含むproject root配下の
  managed path成分のsymlink検査のみ。root外の宣言pathは lnako の環境検証に
  委ねる。profile・命令メタデータ・lockグラフの完全一致は #61 の範囲。
- 取り込み元の依存scopeは package path の包含（最長一致）で近似する。
  lnako 本体は edge 由来の owner を優先するため、入れ子の mutable path 依存で
  owner が包含関係と食い違う構成は #61 の実装範囲。
- `reject-symlink-escape` の拒否は `lnako sync` のtree hash検証（委譲先）で
  起きる。loader側の realpath 包含検査は `--no-sync` で外部環境を読む場合の
  defense-in-depth。

## 検証範囲外

- lnako AOT O0〜O3 の生成物実行は `tests/fixtures/package-aot` と
  `tools/compare_package_import_aot_oracle.mjs`（#209）が担当する。
- package scope の推移 path 依存（`demo` が `../util` を宣言する形）は、
  現状 `lnako sync` の import 依存表生成が、manifest の宣言path
  （`../util`）と lock の project 相対path（`util`）をそのまま比較するため
  `E029_INVALID_VALUE: dependency key "util" has no matching lock package ...`
  で失敗する（`src/package/import_deps.zig` の path 照合。環境検証側
  `src/package/import_resolver.zig` は正規化済みで、生成側だけが非対称）。
  このため共通fixtureには含めていない。root scope の alias 分離は
  `reject-scope-alias` で固定する。
