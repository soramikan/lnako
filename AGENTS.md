# AGENTS.md

## プロジェクト

`lnako` は、なでしこ3 v3.7.24互換のZig＋LLVMネイティブコンパイラです。実装済み範囲は必ず `compat/` のデータとテスト結果に一致させ、未実装機能を完成済みと記述しないでください。

## 必須ルール

- Zig 0.16.0、LLVM/LLD 22.1.8を基準にする。
- 公式なでしこ3のTypeScriptコードを製品ランタイムへ組み込まない。
- 変更した機能には単体テストを追加する。
- 公式処理系と同一仕様の互換命令・機能は、可能なら公式処理系（cnako）との差分テストも追加する。
- 公式処理系に対応機能が無いlnako独自拡張（低レイヤーAPI等の非互換命令）は、公式差分テストを必須としない。契約・異常系・Interpreter/AOT一致を単体テストで保証すればよい（該当する互換ケースが存在しないため `tests/oracle/` の比較対象にも含めない）。
- `zig build fmt-check`、`zig build test`、関連互換テストの順で検証する。
- 機能とテストが完結した単位で、`type(scope): 日本語自然文` 形式（.gitmessage 準拠）の署名付きコミットを作成する。
- force push、履歴改変、未検証状態のコミットを行わない。
- 通常モードへJavaScriptランタイムを混入させない。JS実行は明示的な `--compat-js` に限定する。
- Issue作成時は `.github/ISSUE_TEMPLATE/`、PR作成時は `.github/PULL_REQUEST_TEMPLATE/` 配下の該当テンプレート（または `pull_request_template.md`）を参照して本文を作成する。

## 互換基準

- Upstream: `kujirahand/nadesiko3`
- Tag: `3.7.24`
- Commit: `aa18c7e`
- 標準cnako命令: 527件
- 正式環境: macOS arm64、Linux x86_64 GNU、Windows x86_64 MSVC

