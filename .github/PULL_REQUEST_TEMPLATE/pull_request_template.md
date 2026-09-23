<!--
Pull Request を作成いただきありがとうございます。
変更の背景や内容、およびローカルでの検証状況を記載してください。
-->

## 関連Issue / Related Issue

- Closes #
- Fixes #

## 変更の概要 / Summary of Changes

<!-- このPRで行った変更の要約を簡潔に記載してください -->

## 変更の種類 / Type of Change

- [ ] 新機能・機能拡張 / New feature
- [ ] バグ修正 / Bug fix
- [ ] 公式互換性の改善・修正 / Compatibility fix
- [ ] パフォーマンス改善 / Performance improvement
- [ ] リファクタリング・内部構造改善 / Refactoring
- [ ] ドキュメントの追加・修正 / Documentation
- [ ] CI・ビルド・開発ツールの整備 / Tooling or CI

## 変更内容の詳細 / Detailed Description

<!-- 設計上の判断理由、背景、影響範囲などを記載してください -->

## 検証チェックリスト / Verification Checklist

PRを提出する前に、以下の項目を確認・完了してください。

- [ ] **テストの追加**: 変更した機能に対応する単体テストを追加した
- [ ] **差分テストの追加**: （公式互換機能の場合）公式処理系（cnako）との差分テストを追加した
- [ ] **コード整形**: `zig build fmt-check` がエラーなく通る
- [ ] **単体テスト全実行**: `zig build test --summary all` がすべて成功する
- [ ] **互換性整合性**: （互換台帳を変更した場合）`node tools/sync_compat.mjs --check` および `node tools/sync_compat_evidence.mjs --check` が通る
- [ ] **証拠更新**: （製品変更に伴い必要な場合）`node tools/update_current_evidence.mjs` で証拠を再生成し、コミットに含めた
- [ ] **コミット規律**: コミットメッセージが日本語で記述され、GPG/SSH署名が付与されている
- [ ] **ランタイム分離**: 通常モードにJavaScriptランタイムが混入していない（JS実行は明示的な `--compat-js` に限定）
- [ ] **ドキュメント規律**: （ドキュメント修正がある場合）日本語の「」や（）を含む文にMarkdownの二重アスタリスク強調を使っていない
