# なでしこ3 パッケージシステム仕様案

## 1. 目的とスコープ

本書は `lnako` 先行実装用の、なでしこ3 処理系をまたいで利用できるパッケージシステムの規範仕様案を定義する。

- 本仕様は **lnako リポジトリ内の提案文書**であり、上流 `nadesiko3` に採用済みではない。
- 本書は package マニフェスト、ロック、レジストリ契約、配包形式、resolver/import 契約、および検証に必要な schema と適合例を対象とする。
- package resolver、cache、import、CLI 実装は本 Issue では行わない。これらは Issue #44 以降で実装する。
- 既存の nadesiko3 v3.7.24 互換性証拠（`compat/v3.7.24/`）の互換ケースと判定は変更しない。ただし lnako のビルド成果物やソース manifest が変わる場合は、証拠中の `binarySha256`・`sourceManifestSha256`・`compileManifestSha256` 等の hash を `tools/sync_compat_evidence.mjs` で再同期する（判定結果は不変）。package 仕様の適合性証拠は `tools/package-system/conformance/` および `docs/package-system/` で別に管理する。

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

`nako.toml` は TOML 1.0 準拠。構文上のネスト（配列・inline テーブル）の深さは最大 256 段とし、超過は `E020_INVALID_TOML` とする（深い有効入力による再帰でスタックを枯渇させないため）。

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
| `license` | string | yes | SPDX license expression または `UNLICENSED`/`Proprietary`。expression は構文のみ検査する（識別子が SPDX 公式一覧に登録済みかは問わない）。演算子は `AND`/`OR`/`WITH`（大文字）、`+` 接尾、括弧（最大 32 段）を許容する。識別子の文字集合は `[A-Za-z0-9.-]` で、コロンは `DocumentRef-<id>:LicenseRef-<id>` 複合形の区切りとしてのみ許容する（両 `<id>` は非空）。`+` 接尾は license-id のみに適用し、`LicenseRef-` 単体・DocumentRef 複合形・`WITH` の例外識別子には付けられない。`WITH` の例外識別子には `:`（DocumentRef 複合形を含む）を許容しない。`LicenseRef-`/`DocumentRef-` 接頭辞は非空 idstring が必須（`DocumentRef-<id>` 単体は通常識別子として受理される）。演算子・識別子と括弧の間の空白は任意。不正値は `E029_INVALID_VALUE`。 |
| `id` | string | no | `pkg:<32hex>`。未登録時は省略。 |
| `description` | string | no | 人間向け説明。 |
| `authors` | array<string> | no | 作者リスト。 |
| `keywords` | array<string> | no | 検索用キーワード。 |
| `repository` | string | no | ソースリポジトリ URL。 |
| `homepage` | string | no | ホームページ URL。 |
| `nako-version` | string | no | 想定する nadesiko3 バージョン。 |
| `min-nako-version` | string | no | 必要な最低 nadesiko3 バージョン。 |
| `schema-version` | integer | no | manifest schema 版。省略時は `1`（§9 / SCHEMA_VERSIONS.md 参照）。 |
| `runtimes` | array<string> | no | 対応処理系の配列。要素は `"lnako"`, `"cnako"`。未指定時は両対応とみなす。明示する場合は1要素以上を要求し、空配列は `E029_INVALID_VALUE`。 |
| `engines` | table | no | 言語・処理系エンジンの必要バージョン制約（SemVer range）。キーは `nako`, `cnako`, `lnako`。判定対象バージョンが不明なキーは未検査として扱う。 |
| `include` | array<string> | no | パッケージに同梱するファイルパスまたはglobパターンの配列。未指定時は非除外ファイルをすべて同梱。 |

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
| `prefer-native` | boolean | no | `true` の場合、対象exportに高速化用native実装が存在すればそれを優先選択する（lnako実行時のみ有効）。 |

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

`url` は `format: "uri"` の絶対 URI（`scheme:` を必須とし、空白・制御文字を含まない）とする。scp 形式の `git@host:path` は URI ではないため `ssh://git@host/path` の形式で記述する。`package.repository`・`package.homepage` も同じ形式とする。

### 3.5 profiles セクション

```toml
[profiles]
default = { runtime = "lnako", os = "macos", cpu = "aarch64", abi = "gnu", compat-js = false }
```

| キー | 型 | 必須 | 説明 |
|------|------|------|------|
| `runtime` | string | no | `lnako`, `cnako`, `any`（または `common`）のいずれか。省略時は `any`。 |
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
- `esm` は ESM ファイル。`cnako` または `lnako` の `compat-js = true` 指定時のみ扱う。
- `native`/`esm` は対象条件付きの複数 artifact を宣言できる。文字列は `{ path = <文字列> }` の省略形、テーブルまたはその配列で複数候補を宣言する:

```toml
[[exports]]
name = "plugin"
native = [
  { path = "lib/plugin.dylib", when = "os == 'macos'", min-os = "14.0" },
  { path = "lib/plugin.so", when = "os == 'linux'", libc = "gnu" },
]
```

  - `path`（必須）: artifact の package 内相対パス。
  - `when`: 対象条件を表す marker 式（3.8 節）。評価が真の宣言のみ選択対象となる。
  - `min-os`: 対象 OS の最小バージョン（`.` 区切りの数列）。対象側の OS version が不明な場合は適合を証明できないため、その宣言は選択されない。
  - `libc`: 要求 libc 系（`gnu`/`msvc`/`musl`/`none`）。対象の libc（未指定時は abi）と一致しない宣言は選択されない。
  - `features`: この artifact が要求する feature 名の配列。対象で有効化されていない feature を要求する宣言は選択されない。
  - 空配列・path なしテーブルは `E019`/`E029`、未知フィールドは `E022`、不正な `when` は `E026`、不正な `min-os`/`libc` は `E029`。
  - 複数宣言がある場合、対象に適合する最初の宣言が選択される。どの宣言も適合しない場合、その artifact 種別は対象では利用不能とみなす。
- 同じ `name` の export を重複して宣言できない。
- **実装選択の優先契約**（対象処理系は `lnako` または `cnako`。それ以外の処理系は `path` の有無にかかわらず `E031_UNSUPPORTED_RUNTIME`）:
  - `path`（共通ソース）が宣言されている場合は常に `path` が優先選択される。`dependencies.pkg` で `prefer-native = true` が明示され、かつ対象処理系が `lnako` の場合のみ、`native` が高速化実装として優先される（`cnako` ではフラグを無視して `path` を選択する）。
  - `path` が無く `native` と `esm` の両方が宣言されている場合、`lnako` では `native`、`cnako` では `esm` を選択する（`cnako` は ESM を直接扱えるため `compat-js` は不要）。
  - `path` と `esm` を併記し `compat-js` が無い場合でも、`lnako` 通常モードでは `path` が選ばれるため `E006_JS_IN_NORMAL_MODE` にはならない。
  - native専用パッケージ（`native` のみ）は `lnako` でのみ解決可能（`cnako` では `E031_UNSUPPORTED_RUNTIME`）。
  - ESM専用パッケージ（`path`・`native` を持たず `esm` のみ）は `cnako` または `lnako` の `compat-js = true` 指定時のみ解決可能（通常lnakoでは `E006_JS_IN_NORMAL_MODE`）。静的 manifest 検証では、`runtimes` 未指定（両対応）または `cnako` を含むパッケージ、あるいは `compat-js` profile を持つ場合は cnako 経路があるため受理し、lnako 専用パッケージの通常モードに限って `E006` を報告する。cnako profile はパッケージが cnako 対応の場合にのみ有効な経路であり、`runtimes` で cnako を否定している矛盾した宣言では数えない。実行時の拒否は `Export.resolve` が対象 runtime へ報告する。

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
- prerelease（`-alpha` 等）は patch 位置まで記述され、かつ major が数値の partial にのみ付けられる（`*-alpha`、`1-alpha`、`1.2-alpha`、`1.x-alpha`、`*.*-alpha` は `E025`）。patch 位置が wildcard の prerelease は捨てて評価する（`1.x.x-alpha`/`1.2.x-alpha` は wildcard 範囲と同等）。全位置が wildcard の partial に付く prerelease も `E025` とする（`*.*.*-alpha`；node-semver はこれを match-all として受理するが、本仕様では拒否する）。wildcard の後続位置も wildcard でなければならない（`*.*`/`1.x.x` は許容、`*.1`/`1.x.5` は `E025`）。build メタデータ（`+build` 等）は任意位置で許容する（`1+build` は `1` と同等）

評価は node-semver と同じく、prerelease 付きバージョンは同一 `(major,minor,patch)` の prerelease 比較子を含む比較子集合でのみ一致する。空文字は全バージョン一致として扱う。各数値要素は `Number.MAX_SAFE_INTEGER`（9007199254740991）以下に制限する。構文エラーは `E025_INVALID_RANGE` 診断、バージョン自体の構文エラーは `E024_INVALID_SEMVER` 診断。

### 3.8 marker 式

ターゲット条件（profile 選択・条件付き依存など後続 issue で導入されるフィールド）に用いる式の構文をここで正規化する。

```text
or         := and ("or" and)*
and        := unary ("and" unary)*
unary      := "not" unary | "(" or ")" | comparison | operand
comparison := operand (==|!=|<|<=|>|>=|in|"not in") operand
operand    := field | "string" | 'string' | true | false | "[" [operand ("," operand)*] "]"
field      := runtime | os | cpu | abi | compat-js | optimize | version | features
```

- `runtime`/`os`/`cpu`/`abi`/`optimize` は文字列、`compat-js` は真偽値、`version` は SemVer、`features` は文字列リストとして評価する。
- `in`/`not in` は右辺のリストへの membership を評価する。要素の一致判定は `==` と同じ意味論（文字列同士が SemVer として解釈できる場合は SemVer 比較）。比較不能な型同士は一致しない。
- `version` と文字列の比較は文字列を SemVer として解釈する。型が合わない場合は評価エラー。
- 構文エラーは `E026_INVALID_MARKER` 診断。
- `not` 連鎖・括弧・リストリテラルのネスト深さは最大 256 段とし、超過は `E026_INVALID_MARKER` とする（深い有効入力による再帰でスタックを枯渇させないため）。`and`/`or` の項数に上限はない。

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
| `packages` | object | yes | Public ID をキーとする解決済 package マップ。`input.profile` に対応する選択済みグラフ。 |
| `profiles` | object | yes | 使用した profile 条件のマップ。 |
| `profilePackages` | object | no | profile 名をキーとする解決済 package マップ。複数 profile を一つの lock に収録するときに使う。 |

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
  "implementation": "source",
  "artifacts": {
    "source": { "kind": "source", "type": "tar.gz", "sha256": "...", "url": "..." },
    "native": { "kind": "native", "type": ".npkg", "sha256": "...", "url": "..." }
  },
  "npmInstances": {
    "escape-string-regexp@5.0.0": { ... }
  }
}
```

- `source`: package の出典。
- `resolvedFrom`: 実際に情報を取得した source。
- `dependencies`: 直接依存の Public ID 配列。
- `implementation`: 解決時に選択された実装種別（`source`/`native`/`ESM`/`none`）。`path` があれば既定で `source`、`prefer-native` 明示時のみ `native` を記録する。
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

- lock 検証では選択 profile の `runtime` を考慮する。lock の `artifacts` は package 単位の集合で選択済み実装を表さないため、`cnako` または `compat-js = true` の場合を除き、ESM artifact が一つでもあれば保守的に `E006_JS_IN_NORMAL_MODE` とする（実際の選択は解決・import 時の `Export.resolve` が担う）。profile の `runtime` が未知の場合は `E014_INVALID_PROFILE`。選択された `input.profile` が `profiles` に存在しない場合は `E030_UNKNOWN_PROFILE`。

### 4.5 複数 profile の収録と部分更新

- lock は `input.profile` に対応する選択済みグラフを `packages` に持つ。複数 profile を一つの lock に収録する場合、profile 名をキーに `profilePackages` へ各 profile の解決済 package グラフを記録する。`packages` は `profilePackages[input.profile]` と一致する。
- `profiles` は収録した全 profile の runtime・os・cpu・abi・compat-js・optimize を保持する。profile ごとの ESM 可否判定はその profile の runtime と compat-js で行う。
- 排他的な profile 間では同じ Public ID に異なる版を許す。同一 profile の package グラフ内では Public ID ごとに一版とする。
- lnako/cnako が共用する同一 source artifact は、同じ Public ID・版・hash で参照する。profile をまたいで同一 ID・版の source artifact の hash が食い違う lock は不正とする。
- 通常解決では既存 lock の版を優先する。`update` で指定した package だけ優先固定を解除する。指定外の package が変化した場合は、変更元 package を変更理由（`caused_by`）として説明する。
- `--locked` は lock 欠落、未知 `schemaVersion`、`resolverVersion` 不一致、manifest/profile/features/target の変更を検出したとき、lock を書き換えず失敗する。呼出し側は先に意味検証（`validate`）を行い、その上で鮮度判定を行う（鮮度判定自体は入力条件のみを比較し、意味検証を含まない）。
- 鮮度は選択された `input`（`manifestSha256`・`profile`・`features`・`target`）で判定する。manifest の変更は全 profile に影響する `manifestSha256` の変化として検出し、別 profile の選択は `input.profile` の変化として検出する。非選択 profile の `profilePackages` は lock の再生成時に更新する。
- 生成の決定性は `build`/`buildPackages` が生成したモデルを対象とする。これらは package マップ・profile・features・依存辺・artifact をソートして保持する。serializer はモデルのスライス順をそのまま出力するため、手動構築したモデルは正規化しない限り意味的に同じでもバイト列・SHA-256 が異なり得る。
- path 依存は可変参照として記録する。path ソース本文の編集は root manifest の SHA-256 を変えないため再解決契機にならない。依存宣言を含む manifest 変更は `manifestSha256` の変化として検出する。

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
- `NAKO-PKG/FILES.toml`（配包ファイルの path/hash/size 索引）
- `NAKO-PKG/commands.json`（公開 command 情報）
- 配包されるソースファイルまたは native artifact

- ソースのみのパッケージ（source-only package）は、C ABI や OS 別 binary を要求せず、`.nako3` ソースとメタデータのみで完結する。
- `package.include` により画像や辞書データ等のデータファイルを同梱でき、パッケージ内相対パスで参照する。
- ネイティブ package は `lnako_plugin_v1` ABI を満たす dynamic library を公開する。SSA IR や LLVM bitcode は配布 ABI として使用しない。

### 6.1 アーカイブ規則

- エントリ名は POSIX `/` 区切りの規範パスとする。`..`・`.`・空の成分、`\`、制御文字（U+0000–U+001F, U+007F）、先頭 `/`、末尾 `/` を含むエントリは `E040_NPKG_NONCANONICAL_PATH` で拒否する。
- `NAKO-PKG/` はメタデータ予約領域であり、payload のパスは `NAKO-PKG/` で始まってはならない。必須3エントリ以外の `NAKO-PKG/` エントリは `E037_NPKG_UNLISTED_ENTRY` で拒否する。
- directory エントリ（末尾 `/`）は配布意味を持たず、末尾 `/` は規範パスに適合しないため `E040_NPKG_NONCANONICAL_PATH` で拒否する。生成側も書き出さない。
- 格納形式は stored のみとする。stored 以外の compression method を持つエントリは検証で拒否する。
- ZIP の local header / central directory の並びはエントリ名のバイト順ソートで固定し、timestamp・comment・extra field は固定値（時刻ゼロ、UTF-8 ファイル名フラグ、stored 格納）とする。同一入力からは同一バイト列が得られなければならない。
- 同名エントリの重複は `E038_NPKG_DUPLICATE_ENTRY` で拒否する。
- `package.include` 未指定時は VCS・生成物（`.git`、`.zig-cache`、`zig-out`、`node_modules`、`.nako`、`nako.lock`、`.DS_Store`）を除く package 内ファイルを再帰収録する。`include` 指定時は既定除外を適用せず、パターン適合のみで収録可否を決める。
- 出力予定の `.npkg` が package root 内にある場合、生成側はそれを収集対象から除外する（再ビルドで前回成果物が payload に混入しないようにするため）。

### 6.2 `NAKO-PKG/METADATA.toml`

manifest を配布形へ正規化した写像。先頭に `schemaVersion = 1` を持ち、次を含む:

- `[package]`: `name`・`version`・`license`・`id`（Public ID）・`description`・`authors`・`keywords`・`repository`・`homepage`・`nako-version`・`min-nako-version`・`runtimes`・`engines`。
- `[[exports]]`: 各 export の `name`・`alias` と `path`/`native`/`esm`。
- `native`/`esm` は artifact 宣言テーブル（`path`・`when`・`min-os`・`libc`・`features`）またはその配列も許容する（3.6 節の構造化形式）。
- `[dependencies]`: manifest の依存宣言のうち配布可能なもののみ。
- `[features]`: feature 定義。
- `nativePluginAbi = "lnako_plugin_v1"`: native artifact を持つ場合に必須。

ファイル索引は METADATA.toml には持たず `FILES.toml` が正本とする。パッケージ境界の外を指す `dependencies.path` 等の配布不能な依存は `E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY` で拒否する。

生成側は決定性のため次の正規形で出力する。フィールド順は固定、`dependencies`/`features` の map 由来キーはバイト順ソート、`exports` は `name` 順ソートとする。artifact 宣言は「条件を持たない単一宣言」のみ文字列省略形、それ以外は `{ path, when?, min-os?, libc?, features? }` のインラインテーブル配列で宣言順を保持して出力する。`package.schema-version`・`include`・`dev-dependencies`・`profiles` は配布メタデータに含めない。

### 6.3 `NAKO-PKG/FILES.toml`

payload ファイルの索引。`schemaVersion = 1` と `[[files]]` の配列を持つ:

```toml
schemaVersion = 1

[[files]]
path = "src/index.nako3"
sha256 = "sha256:<64桁hex>"
size = 1234
```

- `path` は規範パス、`sha256` は `sha256:` + 64桁 hex、`size` はバイト数。
- `NAKO-PKG/` 以下のメタデータエントリは索引に含めない（自己参照を避けるため）。索引対象は payload ファイルのみ。
- 索引は `path` のバイト順ソートで出力する。索引内の path 重複は `E038_NPKG_DUPLICATE_ENTRY`。
- 索引に無い payload エントリは `E037_NPKG_UNLISTED_ENTRY`、索引にあるが archive に無いエントリは `E036_NPKG_MISSING_ENTRY`、hash・size の不一致は `E009_HASH_MISMATCH`。

### 6.4 `NAKO-PKG/commands.json`

公開 command 情報。`schemaVersion` と `commands` 配列を持ち、`.nako3` 公開ソースの AST から静的に導出する。初期化コードや任意のパッケージコードは実行しない。

走査の入口は `exports[].path` の収録済みソースのみとし、そこから静的に解決できる import 閉包を辿る。export されない内部ファイルの公開定義は索引に含めない。

- 公開トップレベル関数: `{ "name", "args": [...], "josi": [...] }`（引数名と助詞の対応配列）。
- 公開トップレベル変数: `{ "name", "variable": true }`。
- `fn`・`async`・`return` のような静的に確定できない値は出力しない。
- `commands` は `name` のバイト順ソートで安定化する。

### 6.5 検証

インストール・利用前の静的検証は次を確認する:

- 必須 `NAKO-PKG` エントリの存在と既知 schema version（未知は `E035_UNKNOWN_NPKG_SCHEMA`）。
- 全エントリ名の規範パス適合と重複なし。全エントリが stored 格納であり、各 local header のファイル名が central directory のエントリ名と一致すること。
- `FILES.toml` と payload エントリ集合の完全一致、各 hash・size の一致。
- `METADATA.toml` の構造・必須フィールド、宣言ファイル（`exports[].path` および全 native/esm artifact の `path`）の収録。
- 対象 profile（os/cpu/abi/min-os/libc/features）と artifact 条件の適合。不適合な native artifact は `E015_NATIVE_FOR_INCOMPATIBLE_TARGET`、未対応 runtime は `E031_UNSUPPORTED_RUNTIME`、engine 要件不適合は `E032_ENGINE_MISMATCH`。
- 通常モードでの ESM artifact 利用は `E006_JS_IN_NORMAL_MODE`。

## 7. Resolver / Import 契約

### 7.1 解決

- 同一 Public ID に対する複数の version 制約は common 範囲を満たすように統合する。
- 互換しない version 制約がある場合は `E003_CONFLICTING_VERSIONS` 診断。
  - manifest 検証時の衝突判定は保守的な近似とし、偽陽性を起こさないことを優先する。1 Public ID あたり最大 1024 経路の積集合候補を保持し、上限を超えた時点で絞り込みを打ち切る。その場合は衝突を見逃す方向でのみ誤り得る。
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

### 7.3 cnako 委譲と環境参照契約

- cnako は依存解決・パッケージ同期を `lnako sync --json` へ委譲できる。
- `lnako sync --json` は解決結果を JSON で標準出力し、解決済み環境メタデータを `.nako/environment.json` に記録する。
- cnako の `--no-sync` 実行時は lnako を起動せず、`.nako/environment.json` の `lockSha256`・`profile`・各パッケージの `path` と命令メタデータを単独で検証する。`lockSha256` は参照先 `nako.lock` の実 SHA-256 と一致することを検証し、環境情報が欠落・破損・版不一致・lockハッシュ不一致の場合は `E034_INVALID_ENVIRONMENT_REFERENCE` を診断する。`lockSha256` は SHA-256 表現のみを許容し、SRI 形式 `sha256-<43文字Base64>=`、`sha256:` + 64桁 hex、生 64桁 hex のいずれかとする。
- 動的呼び出し（文字列指定による動的実行等）で静的に共用性を確認できない機能利用は未検査とし、厳格な共用検査（strict sharing check）において `E033_STRICT_SHARING_FAILED` で拒絶する。共用ライブラリの保証には両処理系での自動テスト実行を必須証拠とする。

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
| `E014_INVALID_PROFILE` | error | profile の os/cpu/abi/runtime が無効。 |
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
| `E031_UNSUPPORTED_RUNTIME` | error | 要求された処理系（lnako/cnako）をパッケージがサポートしていない。 |
| `E032_ENGINE_MISMATCH` | error | 言語・処理系バージョンが `package.engines` 要件を満たしていない。 |
| `E033_STRICT_SHARING_FAILED` | error | 厳格共用検査において静的検証不能な動的機能利用を検出。 |
| `E034_INVALID_ENVIRONMENT_REFERENCE` | error | `.nako/environment.json` の破損・不整合・未存在。 |
| `E035_UNKNOWN_NPKG_SCHEMA` | error | `.npkg` 内 `NAKO-PKG` メタデータの schema version が未知。 |
| `E036_NPKG_MISSING_ENTRY` | error | `.npkg` の必須エントリまたは索引済みファイルが archive に存在しない。 |
| `E037_NPKG_UNLISTED_ENTRY` | error | `FILES.toml` に無いエントリ、または未知の `NAKO-PKG/` エントリが archive に存在する。 |
| `E038_NPKG_DUPLICATE_ENTRY` | error | `.npkg` 内エントリ名または `FILES.toml` 索引の path が重複。 |
| `E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY` | error | パッケージ境界の外を指す path 依存など配布不能な依存を含む。 |
| `E040_NPKG_NONCANONICAL_PATH` | error | `.npkg` エントリ名・索引 path が規範パスでない（`..`・`\`・制御文字等）。 |

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