# AGENTS.md

## プロジェクト

`lnako` は、なでしこ3 v3.7.24互換のZig＋LLVMネイティブコンパイラです。実装済み範囲は必ず `compat/` のデータとテスト結果に一致させ、未実装機能を完成済みと記述しないでください。

## 必須ルール

- Zig 0.16.0、LLVM/LLD 22.1.8を基準にする。
- 公式なでしこ3のTypeScriptコードを製品ランタイムへ組み込まない。
- 変更した機能には単体テストと、可能なら公式処理系との差分テストを追加する。
- `zig build fmt-check`、`zig build test`、関連互換テストの順で検証する。
- 機能とテストが完結した単位で、日本語の署名付きコミットを作成する。
- force push、履歴改変、未検証状態のコミットを行わない。
- 通常モードへJavaScriptランタイムを混入させない。JS実行は明示的な `--compat-js` に限定する。

## 互換基準

- Upstream: `kujirahand/nadesiko3`
- Tag: `3.7.24`
- Commit: `aa18c7e`
- 標準cnako命令: 527件
- 正式環境: macOS arm64、Linux x86_64 GNU、Windows x86_64 MSVC

