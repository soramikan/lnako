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
| [`attestations/`](../compat/v3.7.24/attestations/) | CI実行のattestation snapshot（履歴・現行）。現行の選択は走査型で、pointerファイルは持たない |

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

fixture coverageは `paired: 523`、`compat-js-only: 4`、その他の状態は0です。fixture inventoryは合計420件、native AOT 318件、Interpreter 112件、QuickJS 9件です。inventoryの分類は重複するため、数値を足してfixture総数にしません。

## canonical形とmeasured形

`compat/v3.7.24/` に追跡する証拠は **canonical 形** です。内容クレーム（実行site・trace hash・fixture・公式比較・oracle identity・正規化済みmanifest/出力hash）だけを持ち、揮発するprovenanceは持ちません。`provenance.lnako`（commit・binary/source manifest hash）と `provenance.environment.node` はcanonical形に含めず、`provenance.environment` はcanonical生成環境 `darwin/arm64` のみを宣言します。manifest hashはheaderの絶対 `sourcePath` を、公式比較のstdout/stderr hashは一時path・port・PID・Node版・公式生成eval関数名を正規化してから算出するため、環境や実行のたびに値が変わりません。

CIやattestation検証が生成する **measured 形** は、現行環境・Node版・`lnako` provenanceを保持したままの生成artifactです。`tools/lib/evidence/validators.mjs` は `form`（`"measured"` / `"canonical"`）で2形を区別して検証します。tracked正本はcanonical形として、per-OSのattestation artifactはmeasured形として検証します。

## dispatch証拠

`dispatch-evidence.json` は `lnako.dispatch-evidence.v2` です。現行artifactはmacOS arm64で生成され、Interpreter trace 944 event、AOT trace 1,888 eventを持ち、公式source・公式生成JavaScript・`lnako run`・LLVM AOT O0の比較結果を記録しています。

`dispatch-coverage-evidence.json` は `lnako.dispatch-coverage.v1` の sampled auditです。231 fixture、4,602 site、unambiguousなnative entry 426（unique name 424）を記録します。これは全527 entryの純LLVM AOT実行証明ではなく、同名命令の曖昧な推定も成功証拠として扱いません。canonical正本は `--include-native` の全件実行形で、CIではLinux dedicated shardが正本生成と同じReleaseSafe buildで全件を実行し、merge結果が正本と照合されます（macOS/Windowsのshardは既定の56件部分集合です）。`OS取得`・`OSアーキテクチャ取得`の単独行やホーム・テンポラリ配下のパスなどplatform固有の出力値は、hash化前に固定トークンへ正規化するため、darwin/arm64生成の正本とLinux mergeを跨platformでbyte比較できます。同一platform内での公式処理系とlnakoの出力一致は、各shard内のroute equivalence検査が別途保証します。

global binding、static literal、終了・例外、外部host、公式generated routeの差は、通常の命令siteとは別の証拠namespaceまたはfixture policyで扱います。理由を省略して成功件数だけを増やしません。

## CI attestationとの関係

CIの `attest-dispatch-evidence` jobは、`actions/attest@v4.2.2` のSigstore bundleで次を同一attestationのsubjectとして署名します。

- macOS arm64、Linux x86_64、Windows x86_64のdispatch証拠3件
- native AOT aggregate 1件
- source manifest宣言 `lnako-source-manifest.json`（`lnako.source-manifest.v1`：対象commitとsource manifest SHA-256のcanonical宣言）1件
- `compat/v3.7.24/` のcanonical証拠17件（dispatch・coverage・expected-exit・compat-js・global/directory binding・static系11件）

署名対象は `dispatch-attestation.json`（schema `lnako.dispatch-attestation.v3`）の `subjects`（3 OS）・`trackedSubjects`（canonical証拠のpath＋SHA-256）・`sourceManifest`（宣言名＋SHA-256）に記録されます。宣言はcanonical byte列で、`{schema, commit, sourceManifestSha256}` のみを持ち、誰が生成しても同一byte列になります。`sync_compat_evidence.mjs` は、選択したproofを裏付ける証拠ファイルのdigestが署名subject集合に含まれるentryだけを `verified` へ昇格します。digestが署名集合に無い証拠は `trace-confirmed-unattested` のままです。

canonical `evidence.json` 自体は常時 `trace-confirmed-unattested` を保持し、`verified` を正本へ書き込みません。`verified` は現行source manifestに一致する追跡snapshotから導出されるviewです。現行snapshotの解決は走査型で、`attestations/*/manifest.json` のうち `sourceManifestSha256` が現行source manifestと一致する最大workflowRunを選択します（`current.json` pointerは廃止済み）。選択したsnapshotについて、`check_tracked_dispatch_attestation.mjs` は `source-manifest.json` 宣言のcanonical byte一致・そのdigestが署名subject集合へ含まれること・canonical正本と署名subject digestから導出したcatalogがsnapshotの `catalog-evidence-verified.json` とbyte一致することを要求します。manifestが変わるコード変更では一致するsnapshotが無くなり（feature PRや新しいmain commitでは正常）、新しいsnapshotを追跡するまで導出viewのverifiedは0です。過去runのsnapshotを現在HEADの証拠へ自動転記しない方針は維持します。

直前のmanifestに対応する追跡snapshotはCI run `34402208204`（commit `fb015179478169cf4a595094766d4b9582d2925b`、attempt 1、54/54 job成功）で、3 OSのdispatch証拠とnative AOT aggregateとcanonical証拠17件を同一bundleで署名し、導出viewとして `verified: 527` を達成しました。ただしmanifest入力の変更（パッケージmanifest解析層 `src/package/` の追加）で現行manifestと一致しなくなったため、現行ソースの導出viewは `verified: 0` / `trace-confirmed-unattested: 527` です。新しいCI runのsnapshotを `attestations/<run>/` へ追跡すれば、走査型解決でそのrunが現行となり、導出viewは同じ状態へ戻ります。前manifest用のsnapshot `attestations/34305071458/`（run `34305071458`）、`attestations/34121804812/`（run `34121804812`）、`attestations/34113932297/`（run `34113932297`）は履歴として残しています。

Release workflow（tag push）はpreflightで `sync_compat_evidence.mjs --check`（証拠再生成の一致）・`check_tracked_dispatch_attestation.mjs --require-current`（現行source manifestに一致するsnapshotの存在・公式 `gh attestation verify`・導出catalogの `verified: 527`）を要求します。導出catalogが全527件verifiedでないtag pushはbuild/publishに進めず、GitHub Releaseを作成できません（手動 `workflow_dispatch` の検証実行は対象外）。`--require-current` をゲートとして使うのはReleaseだけです（docs検証は一致snapshot存在時の内部確認に使います）。CIやfeature PRでは一致snapshotを要求しません。

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

canonical正本の更新は `node tools/update_current_evidence.mjs` で行います。全17件を staging へ measured 形で生成してcanonical化し、内容が変わったファイルだけを書き換えます（変更の無い証拠はbyteを維持するため、無関係なPR同士が証拠ファイルで衝突しません）。manifest対象のコード変更は先にstageしてから実行し、コードと証拠を同じコミットにまとめてください。

正本が現行ソースと一致するかの検査は `node tools/check_evidence_freshness.mjs`（coverageを除く16件を連続生成して `freshnessBytes` で比較）と `node tools/check_dispatch_coverage_shards.mjs`（CI artifactのcoverage shardをmergeして正本と照合）です。

互換性の分かりにくい仕様、公式処理系のバグ候補、意図的な制限は [`COMPATIBILITY_QUIRKS.md`](COMPATIBILITY_QUIRKS.md) に、公式結果・lnako結果・経路・差分テストID・TODO識別子を揃えて記録します。
