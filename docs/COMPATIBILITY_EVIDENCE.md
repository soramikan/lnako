# 互換性証拠の運用

この文書は、なでしこ3 v3.7.24の標準527 entryについて、何を証拠と認め、どのJSONを正本として扱うかを定義します。現在の分類・fixture・attestationを区別して扱います。

## 正本ファイル

| ファイル | 役割 |
| --- | --- |
| [`summary.json`](../compat/v3.7.24/summary.json) | 公式カタログと実装分類 |
| [`implemented.json`](../compat/v3.7.24/implemented.json) | 実装台帳と命令名の対応 |
| [`evidence.json`](../compat/v3.7.24/evidence.json) | catalog ID単位のcanonical実行証拠状態 |
| [`dispatch-evidence.json`](../compat/v3.7.24/dispatch-evidence.json) | canonical fixtureの実行site、trace、公式比較 |
| [`dispatch-coverage-evidence.json`](../compat/v3.7.24/dispatch-coverage-evidence.json) | sampled dispatch coverage |
| [`compat-js-evidence.json`](../compat/v3.7.24/compat-js-evidence.json) | QuickJS互換モード専用証拠 |
| [`attestations/`](../compat/v3.7.24/attestations/) | CI実行のattestation snapshot（履歴・現行）と現行pointer `current.json` |

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

fixture coverageは `paired: 523`、`compat-js-only: 4`、その他の状態は0です。fixture inventoryは合計419件、native AOT 317件、Interpreter 112件、QuickJS 9件です。inventoryの分類は重複するため、数値を足してfixture総数にしません。

## dispatch証拠

`dispatch-evidence.json` は `lnako.dispatch-evidence.v2` です。現行artifactはmacOS arm64で生成され、Interpreter trace 944 event、AOT trace 1,888 eventを持ち、公式source・公式生成JavaScript・`lnako run`・LLVM AOT O0の比較結果を記録しています。

`dispatch-coverage-evidence.json` は `lnako.dispatch-coverage.v1` の sampled auditです。228 fixture、4,516 site、unambiguousなnative entry 426（unique name 424）を記録します。これは全527 entryの純LLVM AOT実行証明ではなく、同名命令の曖昧な推定も成功証拠として扱いません。

global binding、static literal、終了・例外、外部host、公式generated routeの差は、通常の命令siteとは別の証拠namespaceまたはfixture policyで扱います。理由を省略して成功件数だけを増やしません。

## CI attestationとの関係

CIの `attest-dispatch-evidence` jobは、`actions/attest@v4.2.2` のSigstore bundleで次を同一attestationのsubjectとして署名します。

- macOS arm64、Linux x86_64、Windows x86_64のdispatch証拠3件
- native AOT aggregate 1件
- `compat/v3.7.24/` のcanonical証拠17件（dispatch・coverage・expected-exit・compat-js・global/directory binding・static系11件）

署名対象は `dispatch-attestation.json`（schema `lnako.dispatch-attestation.v2`）の `subjects`（3 OS）と `trackedSubjects`（canonical証拠のpath＋SHA-256）に記録されます。`sync_compat_evidence.mjs` は、選択したproofを裏付ける証拠ファイルのdigestが署名subject集合に含まれるentryだけを `verified` へ昇格します。digestが署名集合に無い証拠は `trace-confirmed-unattested` のままです。

昇格がcanonical `evidence.json`へ反映されるのは、追跡された現行snapshotが存在するときだけです。`attestations/current.json` が最新runのsnapshotディレクトリ（`attestations/<run>/`）を指し、その `sourceManifestSha256` が現行source manifestと一致する場合に限り、`--check`／`--generate` がそのattestationを自動適用します。manifestが変わるコード変更ではpointerが陳腐化し、一致する新しいsnapshotを追跡するまでverifiedは維持されません。過去runのsnapshotを現在HEADの証拠へ自動転記しない方針は維持します。

直前のmanifestに対応する追跡snapshotはCI run `34121804812`（commit `1c096a13fdd41fc6e60d2dddddae7001604e6571`、attempt 1、54/54 job成功）で、3 OSのdispatch証拠とnative AOT aggregateとcanonical証拠17件を同一bundleで署名し、`verified: 527` を達成しました。ただしmanifest入力の変更（v0.1.0リリース向けのversion更新）で現行manifestと一致しなくなったため、`current.json` は取り外し、canonicalは `verified: 0` / `trace-confirmed-unattested: 527` へ戻ります。新しいCI runのsnapshotを `attestations/<run>/` へ追跡して `current.json` を更新すれば同じ状態へ戻ります。前々manifest用のsnapshot `attestations/34113932297/`（run `34113932297`）も履歴として残しています。

Release workflow（tag push）はpreflightで `attestations/current.json` の存在・`sync_compat_evidence.mjs --check`（source manifest一致＋証拠再生成の一致）・`check_tracked_dispatch_attestation.mjs`（追跡snapshotの公式 `gh attestation verify` と `verified: 527`）を要求します。canonicalが全527件verifiedでないtag pushはbuild/publishに進めず、GitHub Releaseを作成できません（手動 `workflow_dispatch` の検証実行は対象外）。

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
