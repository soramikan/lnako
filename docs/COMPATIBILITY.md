# 互換性の概要

この文書は、なでしこ3 v3.7.24に対する実装分類、実行証拠、3正式OS検証の関係を短く説明する入口です。件数の正本は本文ではなく `compat/v3.7.24/*.json` です。

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

公式カタログ全体は1,145件で、標準cnako以外にブラウザ除外429件、拡張除外189件があります。分類は実装台帳です。fixtureの存在、単一環境のtrace、`native` 分類のいずれも、3 OSのAOT実行証拠とは別です。

## 証拠は二層で読む

### 追跡対象のcanonical証拠

[`compat/v3.7.24/evidence.json`](../compat/v3.7.24/evidence.json) はリポジトリに追跡する機械可読の正本です。現在の状態は次のとおりです。

| state | entry |
| --- | ---: |
| `verified` | 0 |
| `trace-confirmed-unattested` | 527 |
| `unverified` | 0 |

これは、全527 entryについて実行siteとの接続をcanonical台帳へ記録済みであることを示します。`verified` は、追跡された現行attestation snapshot（`attestations/current.json`）が現行source manifestと一致し、かつentryのproofを裏付ける証拠ファイルのdigestが署名subjectに含まれる場合にのみ昇格する状態です。

### CIの一時artifact

CI run `34096852822`（commit `f46147266f5b51668f3251c9d57e449edfdc72b6`、54/54 job成功）が生成した一時catalog artifactは `verified: 358`、`trace-confirmed-unattested: 169`、`unverified: 0` でした。このrunのattestationは3 OSのdispatch証拠とnative AOT aggregateだけを署名対象にしており、coverage・static・global binding・expected exit・compat-jsの各証拠namespaceは署名subjectに含まれていませんでした。attestation対象はcanonical証拠17件へ拡張済みで、以降のrunでは全証拠namespaceが昇格対象になります。

一時artifactの値は、実行環境・署名・artifactの保存期間に依存します。追跡対象のcanonical `evidence.json` は、追跡された現行snapshotと現行source manifestの一致が確認できた場合にのみ `verified` を保持します。

## route別の境界

| route | 役割 | 証拠の入口 |
| --- | --- | --- |
| Interpreter | Zig製Nako SSA IR実行器。通常モードの基準実装 | `dispatch-evidence.json`、通常fixture |
| LLVM AOT | LLVM/LLDで生成した純LLVM実行ファイル | AOT fixture、dispatch coverage、CI artifact |
| QuickJS | `--compat-js`限定の4命令 | `compat-js-evidence.json` |

QuickJS証拠は4 entry、9 case（成功6、期待失敗3）で、native dispatch証拠とは別namespaceです。AOTへのネイティブプラグイン静的組み込みは今後のTODOであり、現行のAOT全件証拠へ含めません。

## 関連文書

- [`COMPATIBILITY_EVIDENCE.md`](COMPATIBILITY_EVIDENCE.md): canonical JSON、state、identity、attestationの詳細
- [`COMPATIBILITY_QUIRKS.md`](COMPATIBILITY_QUIRKS.md): 公式仕様の説明不足・バグ候補・意図的制限
- [`CI.md`](CI.md): CI job構成、macOS 5枠、artifact、失敗時の確認方法
- [`compat/v3.7.24/summary.json`](../compat/v3.7.24/summary.json): 実装分類の正本
- [`compat/v3.7.24/dispatch-evidence.json`](../compat/v3.7.24/dispatch-evidence.json): canonical dispatch証拠
