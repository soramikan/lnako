<!--
ドキュメントの修正、CIワークフロー改善、補助スクリプトの整備に関するPRテンプレートです。
-->

## 関連Issue / Related Issue

- Closes #

## 変更の概要 / Summary of Changes

<!-- ドキュメントやCI、ツールの変更内容を記載してください -->

## 変更対象 / Modified Target

- [ ] ドキュメント (`docs/` または `README.md`)
- [ ] CIワークフロー (`.github/workflows/`)
- [ ] 開発・検証用ツール (`tools/`)
- [ ] ベンチマーク関連 (`benchmarks/`)

## ドキュメント・ツールの検証チェックリスト / Verification Checklist

- [ ] **ドキュメント整合性検査**: `node tools/check_docs_current.mjs` が通る
- [ ] **強調記法ルール**: 日本語の「」や（）を含む文にMarkdownの二重アスタリスク強調を使っていない
- [ ] **CIワークフロー検証**: （ワークフロー変更時）`node tools/check_ci_workflow.mjs` が通る
- [ ] **ツールテスト**: （`tools/` 変更時）対応する `*_test.mjs` がすべて成功する
- [ ] **コード整形**: `zig build fmt-check`（Zigコード変更時）またはコードフォーマットが保たれている
- [ ] **コミット規律**: 日本語の署名付きコミットを作成した
