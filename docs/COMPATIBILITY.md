# 互換性の概要

この文書は、日本語プログラミング言語「なでしこ3」（v3.7.24）に対する実装状況、実行検証の仕組み、3正式OS環境での対応状況、および保証範囲について説明する総合ガイドです。
件数および検証状態の正本は本文ではなく [`compat/v3.7.24/`](../compat/v3.7.24/) 配下のJSONファイル群です。未対応境界や今後の課題については [`TODO.md`](TODO.md) を参照してください。

## 互換基準

| 項目 | 値 |
| --- | --- |
| upstream | `kujirahand/nadesiko3` |
| tag | `3.7.24` |
| commit | `aa18c7e640523938c680958fe731418cc6f7a58f` |
| 標準cnako | 527 entry |
| 正式OS | macOS arm64、Linux x86_64 GNU、Windows x86_64 MSVC |

## 実装分類

`compat/v3.7.24/summary.json` における標準cnakoカタログの分類状況は以下のとおりです。

| 分類 | entry | 意味 |
| --- | ---: | --- |
| `native` | 523 | 通常のZigランタイム／LLVM routeで扱う分類 |
| `compat-js` | 4 | 明示的なQuickJS互換モードだけで扱う分類 |
| `blocked` | 0 | 未対応として意図的に拒否する分類 |

公式なでしこ3のカタログ全体は1,145件存在しますが、標準cnakoの対象外として「ブラウザ専用（429件）」および「拡張機能（189件）」の計618件が除外されます。lnakoの互換対象は標準cnakoの527件です。

## 互換性契約と保証範囲

lnakoは「標準cnako 527 entryについて、追跡されたfixtureと公式v3.7.24 oracleで検証した命令経路」を互換対象とします。`verified: 527` は命令名ごとの証拠状態であり、各命令が受け取り得る全入力値の直積や、Node / ECMAScript / OSの全API境界を網羅した形式証明ではありません。

現行バージョンでは、以下の領域について意図的に保証範囲を限定しています。

- **JavaScript固有命令**：`JS実行` などの4命令は通常モードでは実行せず、明示的な `--compat-js` 指定時のみ動作します。QuickJSは通常のInterpreter/AOTのフォールバックとしては動作しません。
- **ブラウザ専用・拡張命令**：Webブラウザ専用API（DOM操作・Canvas等）や拡張命令は対象外です。
- **正規表現（RegExp）**：共有UTF-16エンジンの検証済み範囲を提供しますが、ECMAScript RegExpの全構文規律やV8のエラーメッセージ完全一致は保証しません。
- **表・疎配列・Buffer・ToPrimitive**：テスト用fixtureで検証した境界を保証し、未定義のプロトタイプチェーンや特殊なデスクリプタの組合せまでは保証しません。
- **Node / Host環境**：loopbackやsynthetic adapterなどの制御された環境をテスト証拠として使用します。実ネットワークの接続性、プロキシ/TLS設定、実GUI起動、外部アーカイブツールの副次効果等は固定仕様としません。
- **ネイティブプラグイン**：`lnako_plugin_v1` 仕様の動的ライブラリ（`.dylib` / `.so` / `.dll`）の読み込みに対応しています。AOT実行ファイルへのプラグイン静的リンク（単一バイナリ化）は後続課題です。
- **AOT動的値ブリッジ**：検証済みの非循環オブジェクトグラフ変換を保証対象とし、一般的な循環参照や複雑なプロトタイプ保持は後続課題として扱います。
- **上流固有の未定義動作**：upstream v3.7.24自体のバグ候補やCLI内部ルート差については、それをlnako独自の永続仕様として固定化しません。

個別の境界やTODO識別子は [`TODO.md`](TODO.md) を参照してください。

## 証拠は二層で読む

### 追跡対象のcanonical証拠

[`compat/v3.7.24/evidence.json`](../compat/v3.7.24/evidence.json) はリポジトリに追跡する機械可読の正本です。正本の実行証拠stateは常時 unattested です。外部署名の確認は git 上の snapshot コピーではなく、main CI の `actions/attest` が GitHub Attestations へ記録し、Release preflight が `gh attestation verify` で現行commitの17件のcanonical証拠とsource manifest宣言を検証します。

| state | entry |
| --- | ---: |
| `verified` | <!-- attestation:verified -->0<!-- /attestation:verified --> |
| `trace-confirmed-unattested` | <!-- attestation:trace -->527<!-- /attestation:trace --> |
| `unverified` | <!-- attestation:unverified -->0<!-- /attestation:unverified --> |

<!-- attestation:description-start -->
`verified` は正本へ書き込みません。現行commitのCIが `actions/attest` でcanonical証拠17件とsource manifest宣言を署名し、Release preflightの `check_github_attestation.mjs` が公式 `gh attestation verify` で導出catalog `verified: 527` を確認します。gitへsnapshotをコピーしてPRする手順は使いません。
<!-- attestation:description-end -->

コードを変更した場合は、そのcommitのCI attestationを取り直し、release preflightの `sync_compat_evidence.mjs --check` と `check_github_attestation.mjs` を通過させます。過去commitの署名を流用しません。

<!-- attestation:artifacts-start -->
### CIの一時artifact

main CIの `attest-dispatch-evidence` jobが3 OSのdispatch証拠・native AOT aggregate・source manifest宣言・canonical証拠17件を同一Sigstore bundleのsubjectとして署名し、GitHub Attestationsへ記録します。Release tag pushは同じcommitのCI 46 job構成でのfull相当成功に加え、このattestationを `gh attestation verify` で再確認します。`compat/v3.7.24/attestations/` の過去snapshotはオフライン改変検査用の履歴fixtureであり、現行のverified判定には使いません。

一時artifactの値は実行環境とartifactの保存期間に依存します。追跡対象のcanonical `evidence.json` は常時 `trace-confirmed-unattested` を保持します。
<!-- attestation:artifacts-end -->

## 実行ルート別の特徴

| route | 役割 | 証拠の入口 |
| --- | --- | --- |
| Interpreter | Zig製Nako SSA IR実行器。直接実行（`run`）の基準実装 | `dispatch-evidence.json`、通常fixture |
| LLVM AOT | LLVM/LLDで生成したネイティブ実行ファイル（`build`） | AOT fixture、dispatch coverage、CI artifact |
| QuickJS | `--compat-js` 指定時のみ動作するJavaScript互換実行系 | `compat-js-evidence.json` |

## 関連ドキュメント

- [`TODO.md`](TODO.md): 実装状況、明示的非対応、後続Issueの正本
- [`COMPATIBILITY_EVIDENCE.md`](COMPATIBILITY_EVIDENCE.md): canonical JSON、state、identity、attestationの詳細
- [`COMPATIBILITY_QUIRKS.md`](COMPATIBILITY_QUIRKS.md): 公式仕様との差異・意図的制限の解説
- [`CI.md`](CI.md): CI job構成、検証パイプライン、失敗時の確認方法
- [`compat/v3.7.24/summary.json`](../compat/v3.7.24/summary.json): 実装分類の正本
- [`compat/v3.7.24/dispatch-evidence.json`](../compat/v3.7.24/dispatch-evidence.json): canonical dispatch証拠
