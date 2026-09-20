# 実装状況と未対応境界（TODO）

この文書は、`lnako` の実装状況、現行バージョンにおいて意図的に保証対象外としている境界、および後続Issue・機能拡張計画をまとめた正本です。
互換基準はなでしこ3 v3.7.24（`aa18c7e640523938c680958fe731418cc6f7a58f`）で、標準cnako 527 entryの機械可読な実装・実行証拠は [`compat/v3.7.24/`](../compat/v3.7.24/) を正本とします。

`verified: 527` は、追跡されたfixture・dispatch・公式比較・3 OS attestationに基づく命令entryの実行証拠です。全ての入力値、Node/ECMAScript APIの全境界、実ネットワーク・外部アプリ・任意の外部toolまで完全同値であることを意味しません。未検証境界は本書と [互換性の概要](COMPATIBILITY.md) に明示します。

## リリース済みの状態（v0.1.0 / v0.1.1 / v0.2.0 / v0.2.1）

- **v0.1.0（初回正式リリース）**：
  - 標準cnako 527 entry（native 523、compat-js 4、blocked 0）の実装と、macOS arm64・Linux x86_64・Windows x86_64の3 OSにおけるCI 54/54全job成功・attestation検証を達成。
  - AOT動的値ブリッジのGC root安全性（[#2](https://github.com/soramikan/lnako/issues/2)）、利用者向け導線・配布契約（[#13](https://github.com/soramikan/lnako/issues/13)）、リリースワークフロー（[PR #1](https://github.com/soramikan/lnako/pull/1)）を完了。
- **v0.1.1（入力改善・和文代入拡充）**：
  - 対話型（TTY）における「尋ねる」の一行読み込み・CRLF対応・複数行入力の安定化（[#24](https://github.com/soramikan/lnako/pull/24)）。
  - 連文結果の和文代入、「Aを1に定める」構文、配列・プロパティへの代入の拡充。
- **v0.2.0（パッケージシステム基盤・低レイヤーAPI拡充・証拠管理刷新）**：
  - なでしこ3パッケージシステム仕様案の策定およびZig製PubGrub依存解決器・マニフェスト解析・適合性検証の初期実装（[#66](https://github.com/soramikan/lnako/pull/66), [#67](https://github.com/soramikan/lnako/pull/67), [#69](https://github.com/soramikan/lnako/pull/69), [#79](https://github.com/soramikan/lnako/pull/79)）。
  - 低レイヤーAPIのG0 Foundation、raw標準入出力、ストリームI/O、逐次ハッシュAPI、低層ファイルシステムAPI（stat/lstat/link/rename/unlink）の追加（[#68](https://github.com/soramikan/lnako/pull/68), [#75](https://github.com/soramikan/lnako/pull/75), [#76](https://github.com/soramikan/lnako/pull/76), [#77](https://github.com/soramikan/lnako/pull/77)）。
  - DNCL完全互換と直接コンパイル対応、構造例外責務分割（[#71](https://github.com/soramikan/lnako/pull/71)）。
  - 互換性証拠のcanonical形分離と走査型snapshot解決への移行（[#80](https://github.com/soramikan/lnako/pull/80)）。
  - ドキュメント類の利用者向け全面刷新。
- **v0.2.1（バグ修正リリース）**：
  - HTTPSのAJAX通信およびHTTPリダイレクト時のTLS初期化panicを修正し安定化（[#82](https://github.com/soramikan/lnako/issues/82), [#97](https://github.com/soramikan/lnako/pull/97)）。
  - 先頭のUTF-8 BOM読み飛ばしによるBOM付きソースコード実行への対応（[#94](https://github.com/soramikan/lnako/pull/94)）。
  - インデント構文における『エラーならば』が『違えば』同様にエラー監視スコープを閉じないよう構文解析を修正（[#81](https://github.com/soramikan/lnako/issues/81), [#95](https://github.com/soramikan/lnako/pull/95)）。
  - CI/CDパイプライン改善（変更分類Stage 2、Windows producer最適化、クリティカルパス平準化、GitHub Attestations移行）。

## 明示的に非対応とする境界（意図的制限・後続課題）

以下は標準命令そのものを非対応とする意味ではありません。既存fixtureで検証済みの命令経路は動作しますが、記載した一般化された境界を現行バージョンの保証対象外とします。

| 領域 | 現行の保証外 | 後続Issue |
| --- | --- | --- |
| AOT動的値ブリッジ | 一般の循環object graph、alias identity、疎配列hole、全prototype identityを保持する完全clone | [#3](https://github.com/soramikan/lnako/issues/3) |
| RegExp | ECMAScript RegExp全grammar、未fixtureのUnicode set/string property、複雑なbacktracking、V8エラー本文完全一致 | [#4](https://github.com/soramikan/lnako/issues/4) |
| 表・疎配列 | 全表命令のcustom prototype / inherited property / sparse top-level semantics | [#5](https://github.com/soramikan/lnako/issues/5) |
| Node / Host | 任意の実network topology、外部Internet/TLS/proxy、実GUI launcher、任意7z実装、未fixtureのWindows特殊path/argv | [#6](https://github.com/soramikan/lnako/issues/6) |
| Buffer family | descriptor、未束縛method receiver、全view identityを含むNode object model完全互換 | [#7](https://github.com/soramikan/lnako/issues/7) |
| QuickJS | 4 JS固有命令の成功・期待失敗範囲を越えるエラー本文完全互換 | [#8](https://github.com/soramikan/lnako/issues/8) |
| ToPrimitive / Function | 未fixtureのreceiver副作用順序、function文字列化・辞書key化の全境界 | [#9](https://github.com/soramikan/lnako/issues/9) |
| 上流バグ候補 | DNCL寛容構文、TOML異常入力、generated route登録不足等をlnakoの新しい安定仕様として保証すること | [#10](https://github.com/soramikan/lnako/issues/10) |
| native plugin | `.dylib` / `.so` / `.dll` のdynamic ABIは対応。pluginのAOT静的リンク・単一実行ファイル化は非対応 | [#11](https://github.com/soramikan/lnako/issues/11) |

ブラウザ専用429 entryと拡張189 entryは標準cnako 527 entryの外であり、互換対象外です。JavaScript固有4 entryは通常モードでは実行せず、明示的な `--compat-js` でのみ対象とします。

## 既存TODO識別子の対応状況

| TODO識別子 | 分類 | Issue |
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
| `aot-native-plugin-static-bundle` | 非対応（後続課題） | #11 |
| `compat-js-failure-diagnostic-equivalence` | optional routeの診断改善 | #8 |

## 進行中および今後の継続課題

- **パッケージシステムの実装**：
  - なでしこ3向け共通パッケージシステム仕様案（[SPECIFICATION.md](package-system/SPECIFICATION.md)）に基づく、PubGrub依存解決器、マニフェスト解析を実装済み。`nako.lock` の決定的生成、複数profile集約、既存版優先、部分更新と変更理由説明、lock鮮度判定、`--locked` の無変更失敗を実装した。取得provider・cache・CLI（#47〜#49）は未実装。
- **低レイヤーAPI・ストリームI/O**：
  - 構造化エラーハンドリング、生I/Oストリーム、逐次ハッシュ計算、ファイルシステム低層APIの拡充。
- **性能・最適化の継続管理**：
  - Interpreterの実行速度向上、文字列連結・正規表現の最適化、Windowsバイナリサイズの削減（[#12](https://github.com/soramikan/lnako/issues/12)）。

## リリース時チェックリスト

1. `zig build fmt-check`、`zig build test`、関連oracle・native plugin・distribution self-testを実行する。
2. 最終source commitでCIをfull相当（attestation発行を含む57 job構成）で成功させる。
3. 同じsource manifestの3 OS attestationを追跡し、現行manifestに一致するsnapshotから導出されるviewを `verified: 527`、`unverified: 0` にする。
4. `lnako --version`、`build.zig.zon`、release versionを対象バージョンへ一致させる。
5. 署名済みannotated tag（`vX.Y.Z`）を最終commitに作成してpushする。
6. release workflowで3 OS archive、SHA-256、SPDX 2.3 SBOM、full benchmarkを自動検証してからGitHub Releaseを公開する。
