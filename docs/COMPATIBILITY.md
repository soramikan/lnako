# 互換性の概要

この文書は、なでしこ3 v3.7.24に対する実装分類、実行証拠、3正式OS検証と、lnako 0.1.1で保証する範囲の関係を説明する入口です。件数の正本は本文ではなく `compat/v3.7.24/*.json` です。0.1.1の残課題と保証外境界は [`TODO.md`](TODO.md) を参照してください。

## 基準

| 項目 | 値 |
| --- | --- |
| upstream | `kujirahand/nadesiko3` |
| tag | `3.7.24` |
| commit | `aa18c7e640523938c680958fe731418cc6f7a58f` |
| 標準cnako | 527 entry |
| 正式OS | macOS arm64、Linux x86_64 GNU、Windows x86_64 MSVC |

## 実装分類

`compat/v3.7.24/summary.json` の標準カタログ分類は次のとおりです。

| 分類 | entry | 意味 |
| --- | ---: | --- |
| `native` | 523 | 通常のZigランタイム／LLVM routeで扱う分類 |
| `compat-js` | 4 | 明示的なQuickJS互換モードだけで扱う分類 |
| `blocked` | 0 | 未対応として意図的に拒否する分類 |

公式カタログ全体は1,145件で、標準cnako以外にブラウザ除外429件、拡張除外189件があります。この618 entryは0.1.1の標準cnako互換対象外です。分類は実装台帳であり、fixtureの存在、単一環境のtrace、`native`分類だけでは3 OSのAOT実行証拠を意味しません。

## 0.1.1の互換性契約

0.1.1は「標準cnako 527 entryについて、追跡されたfixtureと公式v3.7.24 oracleで検証した命令経路」を互換対象とします。`verified: 527` は命令名ごとの証拠状態であり、各命令が受け取り得る全入力値の直積や、Node / ECMAScript / OSの全API境界を網羅した形式証明ではありません。

次は0.1.1で意図的に保証範囲を限定します。

- JavaScript固有4 entryは通常モードではなく、明示的な `--compat-js` だけで実行します。QuickJS自体を通常Interpreter/AOTのfallbackにはしません。
- ブラウザ専用429 entryと拡張189 entryは対象外です。
- RegExpは共有UTF-16 engineの検証済み範囲を提供しますが、ECMAScript RegExp全grammarとV8エラー本文の完全一致を保証しません。
- 表・疎配列・Buffer family・ToPrimitiveは既存差分fixtureで検証した境界を保証し、未fixtureの全prototype/descriptor/identity組合せまでは保証しません。
- Node / Hostはloopback・synthetic topology・安全なhost adapter等の制御fixtureを互換証拠に使います。実Internet、任意proxy/TLS、実GUI launcher、実network interface集合、任意7z実装の副作用・列挙順・raw bytesは固定仕様にしません。
- native pluginは `lnako_plugin_v1` のdynamic `.dylib` / `.so` / `.dll` loaderをInterpreterとAOTで提供します。AOT実行ファイルへのplugin静的リンク／単一ファイル化は0.1.1非対応です。
- AOTと動的Interpreter間の一般object graph変換は、0.1.1では検証済みの非循環経路を保証対象とします。一般の循環参照・alias identity・全hole/prototype identityは後続Issueで扱います。
- upstream v3.7.24自体のバグ候補やCLI/generated route差は、その挙動をlnako独自の永続仕様として拡張しません。固定oracleとの差分と意図的制限を領域別文書に残します。

個別の非対応境界、TODO識別子とIssue番号は [`TODO.md`](TODO.md) が正本です。

## 証拠は二層で読む

### 追跡対象のcanonical証拠

[`compat/v3.7.24/evidence.json`](../compat/v3.7.24/evidence.json) はリポジトリに追跡する機械可読の正本です。現在の状態は次のとおりです。

| state | entry |
| --- | ---: |
| `verified` | <!-- attestation:verified -->527<!-- /attestation:verified --> |
| `trace-confirmed-unattested` | <!-- attestation:trace -->0<!-- /attestation:trace --> |
| `unverified` | <!-- attestation:unverified -->0<!-- /attestation:unverified --> |

<!-- attestation:description-start -->
これは、全527 entryの実行証拠が追跡された現行attestation snapshot（`attestations/current.json` → `attestations/34404383555/`）で署名済みであることを示します。`verified` は、`attestations/current.json` が指す現行snapshotのsource manifest（`240004aaf937e2bc7a06057718e6072823549a613a7712a98863d407c0637ab4`）と現行ソースが一致し、かつcanonical証拠ファイルのdigestが署名subjectに含まれる場合にのみ維持される状態です。sourceに変更を加えた場合、過去snapshotの `verified: 527` を流用せず、mainマージ後の新しいCI attestationを再取得して `current.json` を更新します。
<!-- attestation:description-end -->

0.1.1の最終sourceでコードを変更した場合は、過去snapshotの527件をそのままリリース証拠として流用しません。最終source manifestに対してCIとattestationを取り直し、release preflightの `sync_compat_evidence.mjs --check` と `check_tracked_dispatch_attestation.mjs` を通過させます。

<!-- attestation:artifacts-start -->
### CIの一時artifact

現行manifestに対応するCI run `34404383555`（commit `0197463a083d8240f2c79c8f2c031490c044a07a`、54/54 job成功）が生成したcatalog artifactは `verified: 527`、`trace-confirmed-unattested: 0`、`unverified: 0` です。このrunのattestationは3 OSのdispatch証拠・native AOT aggregate・canonical証拠17件を同一Sigstore bundleのsubjectとして署名しており、snapshotは `attestations/34404383555/` に追跡しています。前manifest用のsnapshot `attestations/34305071458/`（run `34305071458`）と `attestations/34121804812/`（run `34121804812`）、`attestations/34113932297/`（run `34113932297`）は履歴として残しています。

一時artifactの値は、実行環境・署名・artifactの保存期間に依存します。追跡対象のcanonical `evidence.json` は、追跡された現行snapshotと現行source manifestの一致が確認できた場合にのみ `verified` を保持します。
<!-- attestation:artifacts-end -->

## route別の境界

| route | 役割 | 証拠の入口 |
| --- | --- | --- |
| Interpreter | Zig製Nako SSA IR実行器。通常モードの基準実装 | `dispatch-evidence.json`、通常fixture |
| LLVM AOT | LLVM/LLDで生成した通常モードのネイティブ実行ファイル | AOT fixture、dispatch coverage、CI artifact |
| QuickJS | `--compat-js`限定の4命令 | `compat-js-evidence.json` |

QuickJS証拠は4 entry、9 case（成功6、期待失敗3）で、native dispatch証拠とは別namespaceです。AOT native pluginはdynamic loader経路を提供しますが、pluginの静的同梱は標準527 entryの互換性とは別の後続製品機能です。

## 関連文書

- [`TODO.md`](TODO.md): 0.1.1必須、明示的非対応、後続Issueの正本
- [`COMPATIBILITY_EVIDENCE.md`](COMPATIBILITY_EVIDENCE.md): canonical JSON、state、identity、attestationの詳細
- [`COMPATIBILITY_QUIRKS.md`](COMPATIBILITY_QUIRKS.md): 公式仕様の説明不足・バグ候補・意図的制限
- [`CI.md`](CI.md): CI job構成、macOS 5枠、artifact、失敗時の確認方法
- [`compat/v3.7.24/summary.json`](../compat/v3.7.24/summary.json): 実装分類の正本
- [`compat/v3.7.24/dispatch-evidence.json`](../compat/v3.7.24/dispatch-evidence.json): canonical dispatch証拠
