# 互換性証拠の運用

この文書は、なでしこ3 v3.7.24の標準527 entryについて、何を証拠と認め、どのJSONを正本として扱うかを定義します。進捗日誌や過去runの数値は [`docs/history/`](history/) に分離しています。

## 正本ファイル

| ファイル | 役割 |
| --- | --- |
| [`summary.json`](../compat/v3.7.24/summary.json) | 公式カタログと実装分類 |
| [`implemented.json`](../compat/v3.7.24/implemented.json) | 実装台帳と命令名の対応 |
| [`evidence.json`](../compat/v3.7.24/evidence.json) | catalog ID単位のcanonical実行証拠状態 |
| [`dispatch-evidence.json`](../compat/v3.7.24/dispatch-evidence.json) | canonical fixtureの実行site、trace、公式比較 |
| [`dispatch-coverage-evidence.json`](../compat/v3.7.24/dispatch-coverage-evidence.json) | sampled dispatch coverage |
| [`compat-js-evidence.json`](../compat/v3.7.24/compat-js-evidence.json) | QuickJS互換モード専用証拠 |
| [`attestations/`](../compat/v3.7.24/attestations/) | 履歴・CI実行のattestation資料 |

## stateの意味

| state | 意味 |
| --- | --- |
| `verified` | 実行証拠に加え、定義された外部署名attestationまで確認済み |
| `trace-confirmed-unattested` | Interpreter/AOT等の実行siteと比較結果をcanonical台帳へ接続済みだが、外部署名attestationは別途確認する状態 |
| `unverified` | 現行canonical証拠へ実行siteを接続できていない状態 |

「命令分類が `native`」「fixtureが存在する」「artifactが生成された」「traceに似た名前がある」は、単独では `verified` に昇格する条件ではありません。重複命令名は表示名ではなくcatalog IDで識別します。

## 現行canonicalの状態

`evidence.json` は schema version 2、527 entry、同名異plugin 31組を記録しています。

| execution evidence | entry |
| --- | ---: |
| `verified` | 0 |
| `trace-confirmed-unattested` | 527 |
| `unverified` | 0 |

fixture coverageは `paired: 523`、`compat-js-only: 4`、その他の状態は0です。fixture inventoryは合計414件、native AOT 312件、Interpreter 112件、QuickJS 9件です。inventoryの分類は重複するため、数値を足してfixture総数にしません。

## dispatch証拠

`dispatch-evidence.json` は `lnako.dispatch-evidence.v2` です。現行artifactはmacOS arm64で生成され、Interpreter trace 944 event、AOT trace 1,888 eventを持ち、公式source・公式生成JavaScript・`lnako run`・LLVM AOT O0の比較結果を記録しています。

`dispatch-coverage-evidence.json` は `lnako.dispatch-coverage.v1` の sampled auditです。227 fixture、4,489 site、unambiguousなnative entry 426（unique name 424）を記録します。これは全527 entryの純LLVM AOT実行証明ではなく、同名命令の曖昧な推定も成功証拠として扱いません。

global binding、static literal、終了・例外、外部host、公式generated routeの差は、通常の命令siteとは別の証拠namespaceまたはfixture policyで扱います。理由を省略して成功件数だけを増やしません。

## CI attestationとの関係

最新の成功例は [`CI run 33748912548`](https://github.com/soramikan/lnako/actions/runs/33748912548) です。commit `6f9dd45946c951d96cf3e3bc6d734980b19d7a9f` で54/54 jobが成功し、macOS arm64、Linux x86_64、Windows x86_64のdispatch attestationを実行しました。CIの一時catalog artifactは `verified: 358`、`trace-confirmed-unattested: 169`、`unverified: 0` でした。

この値はCI実行に紐づく一時成果物です。canonical `evidence.json`へ機械的に転記せず、artifactの署名・provenance・対象commitを併せて確認します。過去attestation資料を現在HEADの証拠に自動転記しない方針も維持します。

## route別の扱い

- 通常モードは純Zig InterpreterまたはLLVM AOTです。JavaScript runtimeを暗黙にfallbackさせません。
- QuickJSは `--compat-js` でのみ有効です。4 entry、9 case（成功6、期待失敗3）を `compat-js-evidence.json` で別管理します。
- `lnako_plugin_v1` のdynamic loaderと `run` / `test` ABIは別途検証します。AOTへのネイティブプラグイン静的組み込みは今後のTODOです。
- 終了・意図的失敗・外部プロセス・実OS依存値は、成功経路のdispatch coverageへ無理に混ぜません。

## 再生成・検査

```sh
node tools/sync_compat.mjs --check
node tools/sync_compat_evidence.mjs --check
node tools/check_compat_report.mjs
node tools/check_dispatch_attestation_security.mjs
node tools/check_tracked_dispatch_attestation.mjs --offline
```

互換性の分かりにくい仕様、公式処理系のバグ候補、意図的な制限は [`COMPATIBILITY_QUIRKS.md`](COMPATIBILITY_QUIRKS.md) に、公式結果・lnako結果・経路・差分テストID・TODO識別子を揃えて記録します。
