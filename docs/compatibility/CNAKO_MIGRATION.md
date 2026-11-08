# cnakoからの移行

この文書は、公式 cnako3 v3.7.24 を使っている利用者が lnako へ移行するときの、実行方法・パッケージ取り込み・名前空間・既知の差異をまとめます。命令単位の互換性は[互換性の概要](../COMPATIBILITY.md)、未対応境界は[実装状況と未対応境界](../TODO.md)を参照してください。

## 1. 実行方法の対応

公式 cnako3 は Node.js 上で動作します。lnako は Zig 実装の Interpreter と LLVM AOT の2経路を持ち、Node.js を必要としません。

| cnako3 | lnako | 備考 |
| --- | --- | --- |
| `cnako3 program.nako3` | `lnako run program.nako3` | Interpreter で実行 |
| — | `lnako check program.nako3` | 構文・意味・中間表現の検査（実行しない） |
| — | `lnako build program.nako3 -o program` | ネイティブ実行ファイルを生成 |
| JS固有命令（`JS実行` など） | `lnako run ... --compat-js` | 明示指定時だけ QuickJS 経路を使う |

- 標準cnakoの527 entryが互換対象です。ブラウザ専用429 entryと拡張189 entryは対象外です。
- JS固有4命令（`JS実行`、`JSオブジェクト取得`、`JS関数実行`、`JSメソッド実行`）は通常モードでは実行せず、`--compat-js` を明示したときだけ動作します。
- `build --compat-js` の既定は embedded（lnako バイナリに source を埋め込む方式）です。LLVM AOT + QuickJS は `--backend aot` の明示的な opt-in です。制約は[QuickJS互換モード](COMPAT_JS.md)を参照してください。

## 2. パッケージ取り込み

公式 cnako3 v3.7.24 は `パッケージ:` 構文を持ちません。lnako の標準表記は次のとおりです。

```nako3
!「パッケージ:demo」を取り込む
!「pkg:demo」を取り込む          # 互換alias。同じ参照に正規化される
!「パッケージ:demo/calc」を取り込む
```

- 両表記は同じパッケージ参照へ正規化されます。新しい文書とサンプルでは `パッケージ:` を使います。
- 依存に無い alias、非公開の subpath、`パッケージ:demo@1.0.0` のような version 指定は拒否されます。
- パッケージ内の相対取り込みはパッケージ境界の内側に限定され、境界外へ出る取り込みと symlink は拒否されます。

cnako との共通ソースを検証するための fixture は `tests/fixtures/package-common/` にあります。ただし cnako 側は lnako の委譲契約を接続するテスト用 adapter（`tools/lib/package/cnako_package_loader.mjs`）で実行しており、cnako 本体への実装は Issue #61 の範囲です。adapter は fixture のソースを書き換えず、公式 cnako3 の `resolvePath` だけを差し替えます。

委譲契約の要点は次のとおりです。

- 依存解決と同期は `lnako sync --json` が行い、`.nako/environment.json` に alias から package key への対応を記録する。
- cnako 側は、その対応表を使って公開 export を解決する。
- cnako の `--no-sync` は lnako を起動せず、`.nako/environment.json` の `lockSha256`、record の形状、alias 衝突、管理 path の symlink を検証する。
- adapter が実行できるのは source export（`.nako3`）だけで、ESM artifact と native artifact は `E031_UNSUPPORTED_RUNTIME` で拒否される。

## 3. namespace（名前空間）の違い

パッケージを取り込んだときの公開名は、両処理系で導出規則が異なります。

| 処理系 | 公開名の導出 | 例 |
| --- | --- | --- |
| lnako | 取り込み alias（subpath 付きは `alias__subpath`） | `パッケージ:demo` → `demo__`、`パッケージ:demo/calc` → `demo__calc__` |
| 公式 cnako3 | 取り込んだファイルの basename | `src/demo.nako3` → `demo__` |

共通 fixture では、export の `path` の basename を lnako の namespace と一致させています。同じ export を `name` 由来の subpath と `alias` 由来の subpath の両方で取り込むと、lnako の namespace は入力した subpath 文字列で変わる一方、cnako は basename 固定のため一致しません。cnako 側の導出を alias 基準へ寄せる作業は Issue #61 の範囲です。

同じ物理ファイルを `パッケージ:` と相対 path の両方で取り込んだ場合も差があります。cnako は filePath で重複を排除して初期化を1回にしますが、lnako は owner 付き identity と owner 無し identity を分離します（[仕様案](../package-system/SPECIFICATION.md)の 7.2 節）。fixture を拡張するときはこの差を前提にしてください。

### plugin 命令名と送り仮名

なでしこの字句解析は動詞の送り仮名を落とすため、命令の dispatch 名は語幹になります。たとえば `整形` という名前で登録した命令は `…を整形する` の形で呼び出せますが、`整形する` という名前で登録した命令は `整形` へ照合されないため呼び出せません。ESM plugin と native plugin の登録名は語幹に合わせてください。なお、公式実装のコメントには、ひらがなで終わるプロパティ名を「」で括らずに参照できない例が記されています（上流の #1859）。

パッケージ経由で取り込んだ plugin 命令は、`{namespace}__{命令名}` の修飾名だけで公開されます。たとえば `pkg:leftpad` を取り込んだ ESM plugin の `整形` は `leftpad__整形` です。同一 artifact を直接 path と package alias の両方で取り込んだ場合は、無修飾名と全修飾名の双方が登録されます。

ESM plugin と npm の bare import は `--compat-js` が必要です。ESM-only の path 依存を `lnako lock` で解決するには、`compat-js = true` を宣言した profile を置きます。参照 fixture は `tests/fixtures/package-plugin-npm/` です。

## 4. 移行手順

1. プロジェクトの `nako.toml` を用意します。新規なら `lnako init`、既存なら手書きでも構いません。
2. 依存を宣言します。ローカル開発中は `[dependencies.path]`、配布済みは `[dependencies.pkg]`、npm は `[dependencies.npm]` です。
3. `lnako lock` と `lnako sync` を実行し、`nako.lock` と `.nako/` を作ります。CI では `--locked` で固定します。
4. `パッケージ:`（または `pkg:`）の取り込みを追加し、呼び出し名を `alias__命令` へ合わせます。
5. JS固有命令と ESM/npm 依存を使う場合は `--compat-js` を付けます。ESM-only の path 依存を含む場合は、lock 用の profile に `compat-js = true` を宣言します。
6. `lnako run` と `lnako build` の両方で結果を比較します。AOT では compat AOT の未対応範囲に注意します。
7. cnako と併用する場合は、cnako 本体の対応（Issue #61）を待つか、テスト用 adapter の制約を理解したうえで検証にだけ使います。

## 5. 既知の差異

| 項目 | 公式 cnako3 v3.7.24 | lnako | 扱い |
| --- | --- | --- | --- |
| `パッケージ:` 構文 | 無い | 標準表記。`pkg:` も受理 | cnako 本体の対応は #61 |
| パッケージ解決 | 委譲 loader（テスト用 adapter）で検証 | 本体に実装済み。残ゲートは #50 を参照 | adapter はテスト専用。診断コードは一致しない |
| 公開名 | 取り込んだファイルの basename | 取り込み alias | 共通 fixture は basename を一致させる |
| 同一ファイルの重複取り込み | filePath で初期化1回 | owner 付き identity で分離 | 仕様どおりの意図的差異 |
| パッケージ境界 | 概念なし | 境界外の取り込みと symlink を拒否 | 安全側 |
| ESM/npm | Node.js が直接解決 | `--compat-js` と lock/cache 経由 | 明示的な opt-in |
| AOT | 無い | Interpreter と LLVM AOT | compat AOT は `--backend aot` の opt-in |
| JS固有4命令 | 常在 | `--compat-js` 指定時のみ | 通常モードへ混入しない |
| ブラウザ専用・拡張命令 | 標準cnakoの対象外 | 対象外 | 互換対象は527 entry |
| RegExp | V8 | 共有UTF-16エンジン | 境界は [TODO](../TODO.md) の Issue #4 |

## 6. 検証

```sh
# cnako/lnako 共通のパッケージ取り込みfixture
node tools/compare_package_import_oracle.mjs

# package import の AOT O0〜O3 比較
node tools/compare_package_import_aot_oracle.mjs

# 委譲loader単体（cnako本体実装ではない）
node --test tools/cnako_package_loader_test.mjs

# ESM plugin と npm bare import の E2E
node tools/check_package_plugin_npm_e2e.mjs
```

`compare_package_import_oracle.mjs` は `--oracle` で公式 nadesiko3 の展開先を指定できます。省略時は `.cache/oracle/nadesiko3-3.7.24` を使います。`compare_package_import_aot_oracle.mjs` は lnako Interpreter と lnako AOT の比較で、`--optimizations` と `--no-build` を受理します。
