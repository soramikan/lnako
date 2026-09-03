# 互換性の注意事項

公式マニュアルだけでは分かりにくい仕様、公式実装のバグ候補、lnakoが安全のために意図的に制限する境界を領域別に記録します。現行項目は次の文書へ分割し、以前の詳細な作業記録は [`docs/history/COMPATIBILITY_QUIRKS_2026.md`](history/COMPATIBILITY_QUIRKS_2026.md) に保全しています。

| 領域 | 内容 |
| --- | --- |
| [Parser](compatibility/PARSER.md) | 正規化、DNCL/DNCL2、インデント、助詞、診断 |
| [Runtime](compatibility/RUNTIME.md) | JSON、値変換、配列・表・辞書、文字列、Promise、正規表現 |
| [Node / Host](compatibility/NODE_HOST.md) | path、stdin、HTTP、process、network、archive、OS境界 |
| [AOT](compatibility/AOT.md) | LLVM、manifest、終了・例外、Buffer、plugin、attestation |
| [QuickJS](compatibility/COMPAT_JS.md) | JS固有4命令と明示的compat-js境界 |

## 記録フォーマット

各項目は、少なくとも次を含めます。

1. 公式v3.7.24の実測結果または固定sourceの根拠
2. lnakoの現在の動作
3. 意図的制限、未実装、または公式バグ候補の区別
4. Interpreter、AOT、QuickJSの対象経路
5. 差分テストID
6. TODO識別子（未完了の場合）

公式の命令一覧は入口として参照し、短い説明から戻り値・例外本文・同期／非同期境界・外部依存を推測しません。固定upstreamは [nadesiko3 `aa18c7e`](https://github.com/kujirahand/nadesiko3/tree/aa18c7e640523938c680958fe731418cc6f7a58f) です。

互換性の証拠状態は [`COMPATIBILITY_EVIDENCE.md`](COMPATIBILITY_EVIDENCE.md)、実装分類は [`COMPATIBILITY.md`](COMPATIBILITY.md) を正本とします。quirksの記録は、証拠stateを自動的に `verified` へ変更するものではありません。
