# 共通oracle基盤（Interpreter / AOT / cnako比較）

Issue [#37](https://github.com/soramikan/lnako/issues/37) の受け入れ条件「同一 `.nako3` fixture を cnako と lnako Interpreter/AOT へ入力し、stdout/stderr/exit code/生成FS状態を比較する共通oracle」の実装方針を固定する。機械可読な命令契約は [`catalog.json`](catalog.json)、型・エラー契約は [`G0_FOUNDATION.md`](G0_FOUNDATION.md) を参照する。

## 方針

- 実行基盤は既存の7経路比較（`tools/compare_native_oracle.mjs`）を再利用する。経路は official source（cnako）、official generated、lnako Interpreter（`run`）、lnako AOT（O0〜O3）である。
- 低レイヤーfixtureは [`tests/oracle/low-level-cases.json`](../../tests/oracle/low-level-cases.json) に追加する。schemaは `lnako.low-level-cases.v1` で、各caseは `id`、`source`、`oracle`（official-source / official-generated）、`commands`（カタログの命令名）、`catalogIds`（命令名→catalog ID）を持つ。
- 低レイヤー命令は `plugin_lowlevel` に登録されるため、`compare_native_oracle.mjs` が要求する標準527命令名の `commands` とは別に、カタログ上の命令名を `commands` に使う。`catalogIds` は `ll-*` のIDを指す。
- 現在は命令未実装のため `low-level-cases.json` は空である。`tools/check_low_level_cases.mjs` がschemaとカタログ連携（未知命令・catalogIds不一致・ID重複）をCIで検証する。#27〜#36の実装に伴いcaseを追加する。
- OS固有値の比較は、既存oracleの `stderrClass` / exit code と、G0の構造化エラー契約（`code` は一致、`nativeCode` / `message` は許容差）に従う。

## 比較対象

| 項目 | 比較するもの |
| --- | --- |
| stdout / stderr | 正規化済み出力（既存oracleの `normalizeDebugDump` 等を利用） |
| exit code / signal | 終了状態 |
| 生成FS状態 | fixtureが作るファイル・ディレクトリの実体（既存 `node-file-cases.json` の手法を踏襲） |
| portable code | 構造化エラーの `code` を3経路で一致させる |
| capability | 同一OSのlnako InterpreterとAOTで `低レイヤー機能対応判定` の真偽を一致させる |

## case追加の手順（#27〜#36向け）

1. `tests/oracle/low-level-cases.json` へ case を追加する。
2. caseの `commands` は [`catalog.json`](catalog.json) の命令名のみを使い、`catalogIds` に `ll-*` ID を書く。
3. `node tools/check_low_level_cases.mjs` が通ることを確認する。
4. 既存 `tools/compare_native_oracle.mjs` のfixture読込へ `low-level-cases.json` を組み込み、7経路で比較する。実装Issueの受け入れ条件でこの実行を要求する。
5. AOT O0〜O3とInterpreterの結果が同一で、Windows/macOS/LinuxのOS差がcapabilityと構造化エラーで表現されていることを確認する。

## 検証

- `node tools/check_low_level_spec.mjs` — カタログJSONとdocsの整合、527件衝突なし、capability整合を検査。
- `node tools/check_low_level_cases.mjs` — 低レイヤーfixtureのschemaとカタログ連携を検査。
- 両ツールはCIの "Verify compatibility baseline" ステップで実行する。

## 非対応の扱い

- 未実装・非対応OSの命令は、fixture実行の代わりに `低レイヤー機能対応判定` と構造化エラー `ENOTSUP` の機械判定を検証する。期待失敗のfixtureは既存oracleのexpected-exit枠に分離する。
- OS固有項目（`nativeCode`、`message`、`conditional` capability）は正規化レイヤーで比較し、portable `code` とcapability真偽だけを3経路で一致させる。