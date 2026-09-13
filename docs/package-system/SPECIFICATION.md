# なでしこ3 パッケージシステム仕様案

## 1. 目的とスコープ

本書は `lnako` 先行実装用の、なでしこ3 処理系をまたいで利用できるパッケージシステムの規範仕様案を定義する。

- 本仕様は **lnako リポジトリ内の提案文書**であり、上流 `nadesiko3` に採用済みではない。
- 本書は package マニフェスト、ロック、レジストリ契約、配包形式、resolver/import 契約、および検証に必要な schema と適合例を対象とする。
- package resolver、cache、import、CLI 実装は本 Issue では行わない。これらは Issue #44 以降で実装する。
- 既存の nadesiko3 v3.7.24 互換性証拠（`compat/v3.7.24/`）は変更せず、package 仕様の適合性証拠は `tools/package-system/conformance/` および `docs/package-system/` で別に管理する。

## 2. 用語

| 用語 | 説明 |
|------|------|
| **Package** | `nako.toml` および付属ファイルの集合体。 |
| **Manifest** | `nako.toml` ファイル。package metadata、依存、features、profiles、exports を記述する。 |
| **Lock** | `nako.lock` ファイル。解決済み package graph、version、source、artifact、hash を記録する。 |
| **Registry** | package index および version/artifact record を提供する source。静的 URL と中央 API の両方を含む。 |
| **Public ID** | `pkg:<32文字の16進数>` 形式の immutable な package 識別子。 |
| **Human ID** | `@owner/name` 形式の人間向け package 識別子。 |
| **Alias** | マニフェスト内で package 名を簡潔に参照する `pkg:sqlite` や `pkg:http/server` 形式の文字列。 |
| **Profile** | 実行対象を `{ os, cpu, abi, compat-js }` で表した条件。 |
| **Artifact kind** | `source`、 `native`、 `ESM` の3種。これ以外の kind は将来拡張用として扱う。 |
| **npm context** | 同一 npm name/version が複数の文脈で登場する場合を区別するための ID。 |

## 3. `nako.toml`

### 3.1 必須セクション

```toml
[package]
name = "sqlite"
version = "1.2.3"
license = "MIT"
```

### 3.2 package セクション

| キー | 型 | 必須 | 説明 |
|------|------|------|------|
| `name` | string | yes | `[a-z][a-z0-9-]{0,63}`（1文字以上）。 |
| `version` | string | yes | SemVer 2.0.0。 |
| `license` | string | yes | SPDX identifier または `UNLICENSED`/`Proprietary`。 |
| `id` | string | no | `pkg:<32hex>`。未登録時は省略。 |
| `description` | string | no | 人間向け説明。 |
| `authors` | array<string> | no | 作者リスト。 |
| `keywords` | array<string> | no | 検索用キーワード。 |
| `repository` | string | no | ソースリポジトリ URL。 |
| `homepage` | string | no | ホームページ URL。 |
| `nako-version` | string | no | 想定する nadesiko3 バージョン。 |
| `min-nako-version` | string | no | 必要な最低 nadesiko3 バージョン。 |
| `schema-version` | integer | no | manifest schema 版。省略時は `1`（§9 / SCHEMA_VERSIONS.md 参照）。 |

### 3.3 features セクション

```toml
[features]
default = ["native"]
http = ["native", "req"]
```

- feature 名は `[a-z][a-z0-9-]+`。
- 値は有効化する feature 名または依存 alias の配列。
- `default` feature は依存解決時に自動的に有効化される。

#### 3.3.1 feature 展開規則

- 要求された feature と（`default-features` が無効化されていなければ）`default` feature を起点に、定義済み feature を深さ優先で再帰展開する。
- 定義の値が定義済み feature 名なら feature として展開し、依存 alias（`dependencies`/`dev-dependencies` のエントリ名または `alias`）ならその依存を有効化する。
- 定義済み feature 名でも依存 alias でもない項目は `E028_UNKNOWN_FEATURE` 診断。
- feature 間の循環は `E027_FEATURE_CYCLE` 診断。循環は解析時にも検査される。

### 3.4 dependencies セクション

依存は source 種別ごとにテーブルを分ける。

```toml
[dependencies.pkg]
req = { version = "^2.0.0", features = ["http"] }

[dependencies.npm]
escape-string-regexp = "5.0.0"

[dependencies.path]
local = { path = "../local" }

[dependencies.git]
sub = { url = "https://github.com/example/sub", commit = "abc123", path = "src" }

[dependencies.http]
data = { url = "https://example.com/data.tar.gz", hash = "sha256-..." }
```

#### 3.4.1 `dependencies.pkg`

| キー | 型 | 必須 | 説明 |
|------|------|------|------|
| `version` | string | yes | バージョン制約（SemVer range）。 |
| `features` | array<string> | no | 有効化する feature 名。 |
| `default-features` | boolean | no | `false` の場合 `default` feature を無効化。 |
| `profile` | string | no | 使用するプロファイル名。 |
| `alias` | string | no | マニフェスト内 alias。 |
| `public-id` | string | no | 解決を固定する Public ID。 |

#### 3.4.2 `dependencies.npm`

npm 補助依存。同一 name/version の npm package が複数文脈で使われる場合、context-specific ID により区別する。

| キー | 型 | 必須 | 説明 |
|------|------|------|------|
| `version` | string | yes | npm version range またはピン。 |
| `context` | string | no | 文脈を表す自由な ID。省略時は package 名を文脈とする。 |
| `features` | array<string> | no | 使用する npm package の feature（peer/optional 含む）。 |
| `peer-dependencies` | object | no | peer 依存マップ（値は semver range）。 |
| `optional-peers` | array<string> | no | optional として扱う peer 名。 |

#### 3.4.3 `dependencies.path`

可変な path 依存。lock 化できない。

| キー | 型 | 必須 | 説明 |
|------|------|------|------|
| `path` | string | yes | 相対・絶対パス。 |
| `mutable` | boolean | no | `false` の場合 hash も記録する。パブリッシュ時は `true` を禁止。 |

#### 3.4.4 `dependencies.git` / `dependencies.http`

出典を明示した取得。git は commit（`[0-9a-f]{7,40}`）で固定する。http は hash で固定する。

### 3.5 profiles セクション

```toml
[profiles]
default = { os = "macos", cpu = "aarch64", abi = "gnu", compat-js = false }
```

| キー | 型 | 必須 | 説明 |
|------|------|------|------|
| `os` | string | yes | `macos`, `linux`, `windows` のいずれか。 |
| `cpu` | string | yes | `aarch64`, `x86_64`, `arm`, `wasm32` のいずれか。 |
| `abi` | string | yes | `gnu`, `msvc`, `musl`, `none` のいずれか。 |
| `compat-js` | boolean | no | `true` の場合 JavaScript/ESM 実行を許可。 |
| `optimize` | string | no | `O0` 〜 `O3`。 |

公式 target:

- `macos-aarch64-gnu`（Apple Silicon）
- `linux-x86_64-gnu`
- `windows-x86_64-msvc`

### 3.6 exports セクション

```toml
[[exports]]
name = "index.nako3"
path = "src/index.nako3"
alias = "sqlite"

[[exports]]
name = "plugin"
native = "libsqlite.dylib"
```

- `name` は export 名。`pkg:foo/bar` 形式の subpath も許可。
- `path` は `.nako3` ファイル。
- `native` は native plugin ファイル。
- `esm` は ESM ファイル。`compat-js` 時のみ扱う。
- 同じ `name` の export を重複して宣言できない。

### 3.7 SemVer range 構文

`version` 制約は npm(node-semver) 互換の範囲構文をとる。

- 完全バージョン `1.2.3`（`=` 等価）
- 部分バージョン `1.2`、`1`、ワイルドカード `1.2.x`/`1.x`/`*`/`x`
- caret `^1.2.3`（`>=1.2.3 <2.0.0`）。`^0` 系は左端の非ゼロ要素を保持する（`^0.2.3` → `>=0.2.3 <0.3.0`、`^0.0.3` → `>=0.0.3 <0.0.4`、`^0.0.0` → `>=0.0.0 <0.0.1`）
- tilde `~1.2.3`（`>=1.2.3 <1.3.0`）、`~1.2`（`>=1.2.0 <1.3.0`）、`~1`（`>=1.0.0 <2.0.0`）。`~>` は `~` と同等
- 比較 `>`, `>=`, `<`, `<=`, `=` の空白区切り AND 結合（`> 1.2.3` のような演算子とバージョンの空白区切りも可）。ワイルドカードへの `>`/`<` は `<0.0.0-0`（空範囲）に写る
- ハイフン範囲 `1.2.3 - 2.0.0`（上端は部分バージョンなら次位まで）
- `||` による OR 結合。空の選択肢は `*` として扱う
- バージョン前置の `v`（`v1.2.3`）は剥がして評価する。先頭の `=`（`=1.2.3`、`= 1.2.3`、`=v1.2.3`）は等価比較の演算子として評価する
- バージョン位置の `=` は受理しない（`==1.2.3`、`> =1.2.3`、`1.2.3 - =2.0.0` は `E025`）。node-semver 7.x は `[v=\s]*` の前置を許容してこれらを受理するが、本仕様は npm/node-semver#691 で提案された次期メジャー仕様（`v?` のみ前置）に合わせて意図的に厳格化する

評価は node-semver と同じく、prerelease 付きバージョンは同一 `(major,minor,patch)` の prerelease 比較子を含む比較子集合でのみ一致する。空文字は全バージョン一致として扱う。各数値要素は `Number.MAX_SAFE_INTEGER`（9007199254740991）以下に制限する。構文エラーは `E025_INVALID_RANGE` 診断、バージョン自体の構文エラーは `E024_INVALID_SEMVER` 診断。

### 3.8 marker 式

ターゲット条件（profile 選択・条件付き依存など後続 issue で導入されるフィールド）に用いる式の構文をここで正規化する。

```text
or         := and ("or" and)*
and        := unary ("and" unary)*
unary      := "not" unary | "(" or ")" | comparison | operand
comparison := operand (==|!=|<|<=|>|>=|in|"not in") operand
operand    := field | "string" | 'string' | true | false | "[" operand ("," operand)* "]"
field      := os | cpu | abi | compat-js | optimize | version | features
```

- `os`/`cpu`/`abi`/`optimize` は文字列、`compat-js` は真偽値、`version` は SemVer、`features` は文字列リストとして評価する。
- `in`/`not in` は右辺のリストへの membership を評価する。要素の一致判定は `==` と同じ意味論（文字列同士が SemVer として解釈できる場合は SemVer 比較）。比較不能な型同士は一致しない。
- `version` と文字列の比較は文字列を SemVer として解釈する。型が合わない場合は評価エラー。
- 構文エラーは `E026_INVALID_MARKER` 診断。

## 4. `nako.lock`

### 4.1 全体構造

```json
{
  "schemaVersion": 1,
  "resolverVersion": 1,
  "input": {
    "manifestSha256": "...",
    "profile": "default",
    "features": ["default", "http"],
    "target": { "os": "macos", "cpu": "aarch64", "abi": "gnu" }
  },
  "packages": { ... },
  "profiles": { ... }
}
```

### 4.2 フィールド

| キー | 型 | 必須 | 説明 |
|------|------|------|------|
| `schemaVersion` | integer | yes | lock ファイル schema version。 |
| `resolverVersion` | integer | yes | 依存 resolver algorithm version。 |
| `input` | object | yes | lock 生成時の入力条件。 |
| `packages` | object | yes | Public ID をキーとする解決済 package マップ。 |
| `profiles` | object | yes | 使用した profile 条件のマップ。 |

### 4.3 package エントリ

```json
{
  "id": "pkg:<hex>",
  "name": "sqlite",
  "version": "1.2.3",
  "source": { "type": "registry", "url": "..." },
  "resolvedFrom": { "type": "registry", "url": "..." },
  "dependencies": ["pkg:<dep-hex>"],
  "features": ["default", "http"],
  "artifacts": {
    "source": { "kind": "tar.gz", "sha256": "...", "url": "..." },
    "native": { "kind": ".npkg", "sha256": "...", "url": "..." }
  },
  "npmInstances": {
    "escape-string-regexp@5.0.0": { ... }
  }
}
```

- `source`: package の出典。
- `resolvedFrom`: 実際に情報を取得した source。
- `dependencies`: 直接依存の Public ID 配列。
- `artifacts`: artifact kind (`source`/`native`/`ESM`) ごとに記録。
- `npmInstances`: npm 補助依存のインスタンス。キーは `<npm-name>@<version>` または context-specific ID。

### 4.4 artifact レコード

| フィールド | 型 | 説明 |
|------------|------|------|
| `kind` | string | `source`, `native`, `ESM`, または将来の kind。 |
| `type` | string | アーカイブ形式。`tar.gz`, `.npkg`, `raw`, `npm-tarball` など。 |
| `sha256` | string | 内容の SHA-256 (base64 または hex)。 |
| `url` | string | 取得 URL。 |

未知の `kind` はエラーとする。将来の kind は schema version bump または `x-` prefix で導入する。

## 5. レジストリ契約

### 5.1 静的レジストリ

- `index.json` に package index 一覧。
- `<owner>/<name>.json` に package ページ。
- `<owner>/<name>/<version>.json` に version record。
- artifact は `https://github.com/owner/repo/releases/download/vX.Y.Z/<filename>` などの静的 URL で配布。

### 5.2 中央レジストリ

- REST/JSON API。
- 応答は静的レジストリと同一 schema であり、同等の hash を返す。
- package 作成時に自動的に Public ID を割り当てる。
- 同一 version に異なる内容を再登録しようとした場合は拒否する。
- 所有者変更は Public ID を変えない。package 名の譲渡は許可しない。

### 5.3 移行

- 旧 lock を中央化しても、同じ version/hash の package を取得できる。
- `source`/`resolvedFrom` フィールドの `type` を `static` から `registry` に更新しても、artifact hash は変わらない。

## 6. `.npkg` 配包形式

`.npkg` は ZIP アーカイブ。必須エントリ:

- `NAKO-PKG/METADATA.toml`
- `NAKO-PKG/FILES.toml`（ファイルパス → hash マップ）
- `NAKO-PKG/commands.json`（公開 command 情報）
- 配包されるソースファイルまたは native artifact

ネイティブ package は `lnako_plugin_v1` ABI を満たす dynamic library を公開する。

## 7. Resolver / Import 契約

### 7.1 解決

- 同一 Public ID に対する複数の version 制約は common 範囲を満たすように統合する。
- 互換しない version 制約がある場合は `E003_CONFLICTING_VERSIONS` 診断。
- feature unification: 異なる依存から要求された feature は和集合で有効化する。
- diamond dependency: 同一 Public ID は graph 内で 1 度だけ解決する。
- cycle: `E004_DEPENDENCY_CYCLE` 診断。
- prerelease: 明示しない限り stable release に解決する。 |
- ambiguous selection: `E005_AMBIGUOUS_SELECTION` 診断。

### 7.2 Import

- `!「pkg:sqlite」を取り込む` のような構文を将来導入する。
- `pkg:` import は resolver によって lock 済みのパスまたは artifact に解決される。
- JavaScript/ESM artifact の import は `--compat-js` 指定時のみ許可する。
- 通常モードで JS/ESM 依存を解決しようとした場合は `E006_JS_IN_NORMAL_MODE` 診断。

## 8. 診断

診断コードは `E###_UPPER_SNAKE` 形式とする。重大度は `error`、`warning` の2種。

| コード | 重大度 | 内容 |
|--------|--------|------|
| `E001_UNKNOWN_MANIFEST_SCHEMA` | error | 不明な `nako.toml` schema version。 |
| `E002_UNKNOWN_LOCK_SCHEMA` | error | 不明な `nako.lock` schema version。 |
| `E003_CONFLICTING_VERSIONS` | error | 同一 Public ID の version 制約が衝突。 |
| `E004_DEPENDENCY_CYCLE` | error | 依存 cycle。 |
| `E005_AMBIGUOUS_SELECTION` | error | 選択に複数候補があり解決できない。 |
| `E006_JS_IN_NORMAL_MODE` | error | `compat-js` なしで JS/ESM 使用。 |
| `E007_UNKNOWN_ARTIFACT_KIND` | error | 未知の artifact kind。 |
| `E008_MISSING_ARTIFACT` | error | 選択した profile に対する artifact が存在しない。 |
| `E009_HASH_MISMATCH` | error | ダウンロード内容の hash が lock と不一致。 |
| `E010_REGISTRY_RECORD_MISMATCH` | error | registry record が静的 metadata と不一致。 |
| `E011_DUPLICATE_EXPORT` | error | export 名の重複。 |
| `E012_ALIAS_COLLISION` | error | alias の衝突。 |
| `E013_MISSING_PACKAGE` | error | package / version / artifact が見つからない。 |
| `E014_INVALID_PROFILE` | error | profile の os/cpu/abi が無効。 |
| `E015_NATIVE_FOR_INCOMPATIBLE_TARGET` | error | native artifact が target と互換でない。 |
| `E016_UNLOCKED_MUTABLE_PATH` | error | locked 動作で可変 path 依存を解決しようとした。 |
| `E017_NPM_PEER_CONFLICT` | error | npm peer dependency 衝突。 |
| `E018_INVALID_NPM_CONTEXT` | error | npm 補助依存の context ID が無効。 |
| `E019_REQUIRED_FIELD_MISSING` | error | 必須フィールドが存在しない。 |
| `E020_INVALID_TOML` | error | `nako.toml` の TOML 構文エラー（重複キー・重複テーブル定義を含む）。 |
| `E021_INVALID_UTF8` | error | manifest が不正な UTF-8 を含む。 |
| `E022_UNKNOWN_FIELD` | error | schema 未定義のフィールド。 |
| `E023_INVALID_TYPE` | error | フィールドの型が schema と不一致。 |
| `E024_INVALID_SEMVER` | error | SemVer として不正なバージョン文字列。 |
| `E025_INVALID_RANGE` | error | SemVer range として不正な制約文字列。 |
| `E026_INVALID_MARKER` | error | marker 式の構文エラー。 |
| `E027_FEATURE_CYCLE` | error | feature 間の循環参照。 |
| `E028_UNKNOWN_FEATURE` | error | 定義済み feature でも依存 alias でもない feature 参照。 |
| `E029_INVALID_VALUE` | error | パターン・列挙に合わないフィールド値。 |
| `E030_UNKNOWN_PROFILE` | error | 未定義の profile 参照。 |

`nako.toml` の解析診断は `path:line:column` のソース位置と `dependencies.pkg.<name>.version` 形式のフィールドパスを保持する。

## 9. 変更規則

- `docs/package-system/SCHEMA_VERSIONS.md` に詳細を記述する。
- 既存フィールドの意味を変える、または必須化する変更は schema version bump が必要。
- 新しい任意フィールドの追加は同じ schema version のマイナー更新としてよい。
- resolver algorithm の決定論的・整合性に影響する変更は resolver version bump が必要。
- 削除された schema version の lock は古い resolver によってのみ解釈される。

## 10. 既存機能との関係

- 既存 `src/semantic/module_graph.zig` の相対パス・JS・native plugin import は、将来 `pkg:` import への拡張基盤となる。
- `src/compat/embedded.zig` の `LNAKOQJSBUNDLE1!` embedded QuickJS 形式は package 配包とは別物であり、引き続き `--compat-js` 限定で使用する。
- 既存 `compat/v3.7.24/` の evidence/summary は変更しない。