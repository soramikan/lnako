# パッケージの作成・公開・配布

この文書は、`nako.toml` を持つパッケージを配布可能な `.npkg` にする手順、インストール前検証、公開機能の現行範囲、配布時の制約をまとめます。`.npkg` の構造・正規形・検証規則の正本は[パッケージシステム仕様案](SPECIFICATION.md)の第6節です。

## 1. 現行バージョンの範囲

| 機能 | 状態 | 入口 |
| --- | --- | --- |
| `.npkg` の生成 | 利用可 | `lnako package build` |
| `.npkg` の静的検証 | 利用可 | `lnako package verify` |
| パッケージキャッシュの管理 | 利用可 | `lnako package cache dir\|clean` |
| 公開（publish）と dry-run | 未実装（予定） | なし |

`lnako package` の操作は `build`・`verify`・`cache` だけです。公開のCLIは Issue #57 の範囲で未実装であり、本書では現行の検証手順と、予定している公開契約の境界だけを記します。

## 2. `.npkg` を作る

`nako.toml` を持つディレクトリで実行します。

```sh
# 既定名 <name>-<version>.npkg でカレントディレクトリに出力
lnako package build

# 出力先を指定（package root の外を推奨）
lnako package build -o dist/pkg.npkg

# 別ディレクトリの package を指定
lnako package build path/to/package -o dist/pkg.npkg
```

- 既定の出力名は `<name>-<version>.npkg` です。version は prerelease と build metadata を含む完全な SemVer 表記を使います。
- 収録対象は package 内のファイルから、VCS と生成物（`.git`、`.zig-cache`、`zig-out`、`node_modules`、`.nako`、`nako.lock`、`.DS_Store`）を除いたものです。`package.include` を指定した場合は、パターン適合だけで収録可否を決めます。
- アーカイブは stored のみの ZIP で、エントリ順・timestamp・extra field を固定した正規形です。同じ入力からは同じバイト列が得られます。
- 書き出し中の出力ファイル自身は収録対象から除外されます。ただし package root に別名の `.npkg` が残っていると、それは payload に含まれます。繰り返しビルドするときは出力先を package の外にするか、既存の `.npkg` を削除してください。
- 生成時にパッケージの初期化コードは実行しません。`NAKO-PKG/commands.json` の公開命令は、公開 export の AST から静的に導出します。辿るのは文字列リテラルの取り込みだけで、文字列テンプレート・識別子・その他の式は実行時にしかパスが決まらないため対象外です。

収録内容は次のとおりです。

- `NAKO-PKG/METADATA.toml`: 配布形へ正規化した manifest
- `NAKO-PKG/FILES.toml`: payload の path・sha256・size 索引
- `NAKO-PKG/commands.json`: 公開関数・変数の索引
- payload: `.nako3`、native/ESM artifact、`package.include` で追加したデータ

ソースのみのパッケージは、C ABI や OS 別 binary を持たずに `.nako3` とメタデータだけで配布できます。

## 3. `.npkg` を検証する

インストールや利用の前に、アーカイブを静的に検証します。

```sh
# 実行環境を対象条件として検証
lnako package verify out.npkg

# 対象条件を明示
lnako package verify out.npkg --runtime lnako --os linux --cpu x86_64 --abi gnu

# compat-js と feature の選択を反映
lnako package verify out.npkg --compat-js --feature http
```

- 対象条件を省略した場合は runtime だけが `lnako` に固定され、os・cpu・abi は未指定として扱われます。`when`・`min-os`・`libc` などの条件付き artifact は適合を証明できないため選択されません。対象環境が決まっている場合は `--os`・`--cpu`・`--abi` を明示してください。
- 主な検査項目は、必須 `NAKO-PKG` エントリと schema、規範パスと重複、stored 格納と CRC、`FILES.toml` と payload の一致、`METADATA.toml` の構造、宣言ファイルの収録、対象環境（runtime・os・cpu・abi・compat-js・optimize）と artifact 条件の適合、engine 要件、通常モードでの ESM 利用（`E006_JS_IN_NORMAL_MODE`）です。
- 検証は静的で、パッケージの初期化コードを実行しません。
- 成功時は `out.npkg: package-common-demo 1.0.0（5 ファイル、5 命令）— 検証 OK` のように収録数と公開命令数を表示します。失敗時は `E0xx` の診断コードと該当ファイルを表示します。
- `verify` に `--json` はありません。

## 4. 公開（publish）

`lnako package publish <root>` は `.npkg` を組み立てて検証し、静的 registry へ冪等に PUT します。既定は dry-run で、外部を変更しません。

```sh
# 検証だけ（既定）
lnako package publish .

# 実際に PUT する
lnako package publish . --no-dry-run --registry https://registry.example --owner myname
```

- 公開前検証: metadata・hash・対象 artifact 一式・path 依存・license を `package verify` 相当で確認します。宣言された全 runtime（未宣言なら `lnako`）について検証し、1 つでも失敗すれば公開しません。source-only パッケージに native ABI や OS 別 binary は要求しません。
- dry-run は外部を変更せず、検証結果だけを返します。
- 再実行は冪等です。同じ版・同じ内容の再実行は成功し（artifact の再 PUT をスキップ）、異なる内容による同版の上書きは拒否します。
- 認証情報は CLI 引数へ直接書かず、環境変数 `LNAKO_REGISTRY_TOKEN` などから渡します。loopback 以外の平文 `http` registry は `--allow-plaintext-http` を明示した場合だけ許可します。
- **`index.json` へも登録します**。順序は「artifact → version record → index」で固定し、version record が存在しないと consumer の解決が失敗するため、この順で PUT します。索引の登録は冪等です（同じ版は追加しない）。索引が未作成の registry では空の索引を作ります。
- 索引の package record は Public ID（`pkg:` + 32 hex）で識別します。manifest に `id` の宣言が無い場合は `registry:<url>` の identity から導出します（consumer の lock と同じ規則）。
- 失敗経路は fails-closed です。誤った token は 401 で拒否し version record を登録しません。npm/git/http 依存を持つ package は公開を拒否します（静的 registry の version record で表現できず、consumer の provider も解決しないため）。path 依存は `.npkg` へ同梱して自己完結させます。

### 4.1 公開時に要求する target 適合

**方針: 公開時に要求するのは「宣言された runtime すべてで検証が通ること」だけで、OS・CPU・ABI の網羅は要求しません。**

- 根拠: なでしこ3 の package は source-only が第一級で、native/ESM artifact を持たない package が大半です。OS 別 binary の網羅を公開条件にすると、source-only package の公開が不可能になります。
- 条件付き artifact（`when`・`min-os`・`libc` など）は、公開時点で「宣言された全条件が妥当か」だけを検査し、**全条件を満たす artifact 一式が揃っていることは要求しません**。ある OS 向け binary だけを公開し、後から追加する使い方を許容します。
- OS 別 binary の充足は **利用者側の `package verify` / `lock` が対象環境で判定**します。対象条件を省略した `verify` は適合を証明できないため artifact を選択しません（§3）。
- 将来、全 target の網羅を必須にする場合は新しい schema version で導入し、既存 package の公開を遡って壊さない方針とします。

現時点で手動配布する場合は、`.npkg` と manifest を GitHub Releases へ置き、静的レジストリの索引を自前で更新する必要があります。索引のレイアウトと record の契約は[仕様案](SPECIFICATION.md)の第5節を参照してください。索引の適合例は `tools/package-system/conformance/valid/registry/`、`.npkg` メタデータの適合例は `tools/package-system/conformance/valid/npkg/` にあります。

## 5. 配布時の制約

| 制約 | 内容 |
| --- | --- |
| `dependencies.path` | package 境界の外を指す path、または依存先 manifest が payload に収録されていない path 依存は `E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY` で配布不可。`mutable = true` の path 依存は現行の `package build` が収録して METADATA.toml へ記録するが、公開時は禁止する予定 |
| `profiles` | 配布メタデータに含まれないため、profile 参照を持つ依存は再現できず拒否 |
| native artifact | `lnako_plugin_v1` ABI の dynamic library のみ。SSA IR や LLVM bitcode は配布 ABI にしない |
| ESM artifact | `compat-js = true` の profile か `cnako` runtime でのみ選択。通常の lnako では `E006_JS_IN_NORMAL_MODE` |
| 通常モードの ESM | `.nako3` 実装と `esm` を併記した場合は `.nako3` が優先され、通常モードでも解決できる |
| Windows の compat AOT | `--compat-js --backend aot` のリンクは未対応。Windows では `--backend embedded` または `run --compat-js` を使う |

`dependencies.pkg` の依存は配布物へ再帰的に同梱されません。利用者側の lock 解決に委ねるため、配布する `.npkg` には自身の payload と、配布可能な path 依存だけが入ります。

## 6. lnako 本体の配布アーカイブ

`build --compat-js --backend aot --sbom <path>` は、生成物へ同梱した npm/ESM package の
license 一覧を SPDX 2.3 JSON として出力します（`--sbom` 無指定なら従来どおり何も出しません）。
同梱 package の同一性は path ではなく file 識別子でも比較するため、生成物や入力 source の
hardlink を `--sbom` に指定した場合も拒否します。

lnako 自身の配布アーカイブは、通常 AOT runtime（`liblnako_runtime.a` / `lnako_runtime.lib`）と compat AOT runtime（`liblnako_runtime_compat.a` / `lnako_runtime_compat.lib`）の両方を `lib/` へ同梱します。`build --compat-js` の既定は embedded で、`--backend aot` は明示的な opt-in です。展開した配布物でも `--backend aot` が動作します。

Windows x86_64 の compat AOT リンクは、Zig の MinGW 向けにビルドした QuickJS が `__mingw_*` と pthread 系のシンボルを参照し、配布 LLVM のリンク行では解決できないため未対応です。詳細は[配布物とリリース手順](../RELEASE.md)と[QuickJS互換モード](../compatibility/COMPAT_JS.md)を参照してください。

## 7. 検証

```sh
zig build package-schema-check
node tools/check_package_schema.mjs
node tools/check_package_isolation.mjs
node tools/check_package_plugin_npm_e2e.mjs   # CI の compat job（-Dcompat-js=true のビルドが必要。SBOM も検査）
node tools/check_package_publish_e2e.mjs      # publish→取得 E2E（CI の 3 OS compat job。-Dcompat-js=true のビルドが必要）
```

`check_package_schema.mjs` は manifest・lock・registry・environment・`.npkg` メタデータの適合例と不適合例を検査します。`check_package_isolation.mjs` は `build.zig.zon` の収録対象だけで通常ビルドと最小 consumer が成立することを検査します。
