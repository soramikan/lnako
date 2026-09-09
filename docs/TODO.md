# 0.1.0 リリースTODO

この文書は、lnako 0.1.0を公開するための残作業と、0.1.0では保証しない境界、後続Issueを分離する正本です。互換基準はなでしこ3 v3.7.24（`aa18c7e640523938c680958fe731418cc6f7a58f`）で、標準cnako 527 entryの機械可読な実装・実行証拠は `compat/v3.7.24/` を正本とします。

`verified: 527` は、追跡されたfixture・dispatch・公式比較・3 OS attestationに基づく命令entryの実行証拠です。全ての入力値、Node/ECMAScript APIの全境界、実ネットワーク・外部アプリ・任意の外部toolまで完全同値であることを意味しません。未検証境界は本書と `docs/compatibility/` に明示します。

## 0.1.0をブロックする項目

| 項目 | 状態 | 完了条件 |
| --- | --- | --- |
| リリース文書・配布契約の整合 | [#13](https://github.com/soramikan/lnako/issues/13) | 本書、互換性文書、RELEASE、配布archive、versionを0.1.0向けに一致させる |
| version・release workflow・canonical attestation | [PR #1](https://github.com/soramikan/lnako/pull/1) | 最終sourceでCI 54/54、`verified: 527`、署名済みannotated `v0.1.0` tag、release asset検証を通す |

[#2](https://github.com/soramikan/lnako/issues/2)（AOT⇔動的InterpreterブリッジのGC root安全性）は解消済み・closedです。#13の利用者向け導線・保証範囲・文書同梱は整備済みですが、最終候補のCI・canonical attestation・公開確認は引き続き必要です。上記の完了条件を満たす前に`v0.1.0`タグを作成しません。

## 0.1.0で明示的に非対応とする境界

以下は標準命令そのものを`blocked`にする意味ではありません。既存fixtureで検証済みの命令経路は対応しますが、記載した一般化された境界を0.1.0の保証対象外とします。

| 領域 | 0.1.0の保証外 | 後続Issue |
| --- | --- | --- |
| AOT動的値ブリッジ | 一般の循環object graph、alias identity、疎配列hole、全prototype identityを保持する完全clone | [#3](https://github.com/soramikan/lnako/issues/3) |
| RegExp | ECMAScript RegExp全grammar、未fixtureのUnicode set/string property、複雑なbacktracking、V8エラー本文完全一致 | [#4](https://github.com/soramikan/lnako/issues/4) |
| 表・疎配列 | 全表命令のcustom prototype / inherited property / sparse top-level semantics | [#5](https://github.com/soramikan/lnako/issues/5) |
| Node / Host | 任意の実network topology、外部Internet/TLS/proxy、実GUI launcher、任意7z実装、未fixtureのWindows特殊path/argv | [#6](https://github.com/soramikan/lnako/issues/6) |
| Buffer family | descriptor、未束縛method receiver、全view identityを含むNode object model完全互換 | [#7](https://github.com/soramikan/lnako/issues/7) |
| QuickJS | 4 JS固有命令の成功・期待失敗範囲を越えるエラー本文完全互換 | [#8](https://github.com/soramikan/lnako/issues/8) |
| ToPrimitive / Function | 未fixtureのreceiver副作用順序、function文字列化・辞書key化の全境界 | [#9](https://github.com/soramikan/lnako/issues/9) |
| 上流バグ候補 | DNCL寛容構文、TOML異常入力、generated route登録不足等をlnakoの新しい安定仕様として保証すること | [#10](https://github.com/soramikan/lnako/issues/10) |
| native plugin | `.dylib` / `.so` / `.dll`のdynamic ABIは対応。pluginのAOT静的リンク・単一実行ファイル化は非対応 | [#11](https://github.com/soramikan/lnako/issues/11) |

ブラウザ専用429 entryと拡張189 entryは標準cnako 527 entryの外であり、0.1.0の互換対象外です。JavaScript固有4 entryは通常モードでは実行せず、明示的な`--compat-js`でのみ対象とします。

## 0.1.0をブロックしない継続課題

- 性能: 最新のリリース候補測定は[ベンチマーク結果](benchmarks/RESULTS.md)を参照してください。Interpreterの性能、文字列処理、WindowsのAOT実行ファイルサイズなどの継続管理は [#12](https://github.com/soramikan/lnako/issues/12)。
- upstream bug候補・route差の再追跡は [#10](https://github.com/soramikan/lnako/issues/10)。0.1.0では固定v3.7.24のoracleと意図的制限を維持します。
- AOT native pluginの静的同梱は [#11](https://github.com/soramikan/lnako/issues/11)。現行dynamic ABIとAOTからの遅延ロードは別機能として対応済みです。

## 既存TODO識別子の対応

| TODO識別子 | 0.1.0分類 | Issue |
| --- | --- | --- |
| `official-dncl-all-elements-tail` | 上流バグ候補。非ブロッカー | #10 |
| `sparse-array-presence` | 部分対応、一般境界は保証外 | #5 |
| `table-inherited-properties` | 保証外 | #5 |
| `regexp-unicode-flags` | 部分対応 | #4 |
| `regexp-js-error-text` | 部分対応 | #4 |
| `regexp-backtracking-edge` | 部分対応 | #4 |
| `toml-temporal-values` | 上流バグ候補／意図的制限 | #10 |
| `catalog-plugin-toml-generated-registration` | upstream generated route差 | #10 |
| `node-path-win32-boundary` | 未検証OS境界 | #6 |
| `node-network-cross-os-attestation` | 実OS依存、保証外 | #6 |
| `node-http-cross-os-attestation` | 実OS／network依存、保証外 | #6 |
| `httpserver-multipart-boundary` | 部分対応 | #6 |
| `aot-node-archive-arbitrary-external-tool-diff` | 外部tool依存、保証外 | #6 |
| `node-exit-cross-os-attestation` | OS依存境界 | #6 |
| `node-http-generated-route-diagnosis` | upstream route差 | #10 |
| `aot-node-windows-wtf8-argv` | 未検証Windows境界 | #6 |
| `aot-byte-buffer-value` | 部分対応 | #7 |
| `aot-object-to-primitive` | 部分対応 | #9 |
| `aot-function-string-name` | 部分対応 | #9 |
| `aot-native-plugin-static-bundle` | 0.1.0非対応 | #11 |
| `compat-js-failure-diagnostic-equivalence` | optional routeの診断改善 | #8 |

## リリース直前チェック

1. #2と#13を完了する。
2. `zig build fmt-check`、`zig build test`、関連oracle・native plugin・distribution self-testを実行する。
3. 最終source commitでCI 54/54 jobを成功させる。
4. 同じsource manifestの3 OS attestationを追跡し、`compat/v3.7.24/evidence.json`を`verified: 527`、`unverified: 0`にする。
5. `lnako --version`、`build.zig.zon`、release versionを`0.1.0`へ一致させる。
6. 署名済みannotated tag `v0.1.0`を最終commitに作成する。
7. release workflowで3 OS archive、SHA-256、SPDX 2.3 SBOM、full benchmarkを検証してからGitHub Releaseを公開する。
