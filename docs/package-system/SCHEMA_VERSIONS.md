# なでしこ3 パッケージシステム schema version 規則

本書は `nako.toml` および `nako.lock`、付随する JSON Schema、レジストリ応答の version/change policy を定義する。

## 1. 用語

| 用語 | 説明 |
|------|------|
| `manifestSchemaVersion` | `nako.toml` の schema version。 |
| `lockSchemaVersion` | `nako.lock` の schema version。 |
| `resolverVersion` | 依存 resolver algorithm の version。 |
| `npkgMetadataSchemaVersion` | `.npkg` 内 `NAKO-PKG/METADATA.toml` の schema version。 |
| `npkgFilesSchemaVersion` | `.npkg` 内 `NAKO-PKG/FILES.toml` の schema version。 |
| `npkgCommandsSchemaVersion` | `.npkg` 内 `NAKO-PKG/commands.json` の schema version。 |

## 2. 初期バージョン

- `manifestSchemaVersion`: 1
- `lockSchemaVersion`: 2 (v1 read-only compatibility)
- `resolverVersion`: 1
- `npkgMetadataSchemaVersion`: 1
- `npkgFilesSchemaVersion`: 1
- `npkgCommandsSchemaVersion`: 1

## 3. `nako.toml` schema version

### 3.1 バージョン表記

マニフェストには必須ではないが、`package.schema-version` フィールドで schema version を宣言できる。

```toml
[package]
name = "sqlite"
version = "1.2.3"
license = "MIT"
schema-version = 1
```

未指定の場合は version 1 とみなす。

### 3.2 変更規則

次の変更は **major version bump** が必要:

- 既存フィールドの意味を変更する。
- 任意フィールドを必須にする。
- フィールドの型を変更する。
- 既存テーブル構造を変更する。
- `dependencies.*` の source 種別を追加・廃止する。

次の変更は同じ major version の **minor 更新** としてよい:

- 新しい任意フィールドの追加。
- 新しい source 種別の追加（既存 source の解釈を変えない場合）。
- 値の許可範囲を拡大する（例: `license` に新しい SPDX identifier を追加）。

### 3.3 非推奨・廃止

- 非推奨フィールドは `deprecated` 注釈を文書に残し、最低 1 minor version 以上の移行期間を設ける。
- 廃止したフィールドを受け取った場合、対応する schema version を持つ parser は `E001_UNKNOWN_MANIFEST_SCHEMA` 相当の診断を出す。

## 4. `nako.lock` schema version

### 4.1 バージョン表記

lock ファイルはトップレベルに `schemaVersion` と `resolverVersion` を必ず含む。schema v2ではprofileごとのroot直接依存IDを `rootDependencies` に記録する。

```json
{
  "schemaVersion": 2,
  "resolverVersion": 1,
  "input": { ... },
  "packages": { ... },
  "profiles": { ... },
  "rootDependencies": { "default": ["pkg:<direct-id>"] }
}
```

### 4.2 変更規則

`lockSchemaVersion` の bump:

- lock ファイルの必須フィールドを変更する。
- root direct dependency IDなど、packageグラフの解釈に必要な辺を追加する。
- `packages` エントリの構造を変更する。
- `artifact` レコードの必須フィールドを変更する。
- `input` セクションを変更する。

`resolverVersion` の bump:

- resolver algorithm の決定論的結果が変わる。
- feature unification、diamond dependency、prerelease、partial update の扱いが変わる。
- 診断コードや重大度が変わる。

`profilePackages` と `implementation` は任意情報の追加であり、旧readerに対しては互換性を持たないもののv1実装が一般流通していなかったためv1内で導入した。root直接依存はsync時のalias解決に必須のグラフ辺であり、推移依存との区別を正確に保持するためschema v2で必須化する。

v1 lockは読み取り可能だが、直接辺が欠落するため互換モードではlock graphのroot nodeから推定する。推定できない複数候補は曖昧なまま捨てず `LockInvalid` とし、v2 lockの再生成を促す。新規生成lockはv2で `rootDependencies` を出力する。旧readerはv2を拒否するため、lock書き手・読み手を同一schema versionへ揃えること。

### 4.3 下位互換

- `schemaVersion` が未知の lock ファイルは読み込まない。`E002_UNKNOWN_LOCK_SCHEMA` 診断。
- `resolverVersion` が未知の lock ファイルは、`--locked` 指定時はエラー、非ロック時は再解決を試みる。

## 5. `.npkg` 内メタデータの schema version

`.npkg` アーカイブ内の `NAKO-PKG` メタデータはそれぞれ独立した schema version を持つ。

| ファイル | version フィールド | 初期 version |
|---------|-------------------|--------------|
| `NAKO-PKG/METADATA.toml` | `schemaVersion` | 1 |
| `NAKO-PKG/FILES.toml` | `schemaVersion` | 1 |
| `NAKO-PKG/commands.json` | `schemaVersion` | 1 |

- 未知の `schemaVersion` を持つ `.npkg` は `E035_UNKNOWN_NPKG_SCHEMA` で拒否する。
- payload ファイルの索引は `METADATA.toml` ではなく `FILES.toml` が正本とする。`METADATA.toml` に `files` フィールドは存在しない。
- 各メタデータの必須フィールド・構造変更は対応する schema version の bump が必要。新しい任意フィールドの追加は同じ major version の minor 更新としてよい。
- `.npkg` エントリのレイアウト規則（規範パス・決定的順序・必須エントリ集合）自体の変更は archive format 変更であり、3エントリすべての major bump として扱う。

## 6. JSON Schema ファイルの version

- `tools/package-system/schema/*.schema.json` は `$id` URL に version を含める。
- 例: `https://github.com/soramikan/lnako/package-system/schema/nako.toml/v1`、`https://github.com/soramikan/lnako/package-system/schema/nako.lock/v2`
- schema ファイル自身は `required`/`additionalProperties` で厳密に version を縛る。

## 7. レジストリ応答の version

- 全てのレジストリ応答 JSON は `schemaVersion` を含める。
- 静的レジストリ index/package/version 応答は、lock schema version と同じ major version スキーマを使う。
- 中央レジストリ API は同等の `schemaVersion` を返す。

## 8. 移行

- 中央レジストリへの移行は、既存 lock の hash を変更しない。
- `source`/`resolvedFrom` の `type` を `static` から `registry` に更新しても、artifact 内容と hash は同じままとする。
- 移行 fixture `valid/lock/central-migration/` はこの性質を示す。

## 9. 今後の予定

- `manifestSchemaVersion` 1: Issue #69 において共通ソース優先、`package.runtimes`、`package.engines`、`package.include`、profile `runtime`、`prefer-native`、および `.nako/environment.json` 契約をインプレースで包含する仕様改訂を実施した。v1/v2 の並行運用や移行ロジックは導入せず、単一正本スキーマとして維持する。
- `lockSchemaVersion` 2: workspace lock、複数ルート package の対応を予定。
- `resolverVersion` 2: optional peer dependency の handling 改善を予定。