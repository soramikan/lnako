<!--
バグ修正および公式なでしこ3互換性修正に関するPRテンプレートです。
-->

## 関連Issue / Related Issue

- Fixes #

## 不具合の原因と修正の概要 / Root Cause & Fix Summary

<!--
- 何が原因で問題が発生していたか
- どのように修正したか
-->

## 修正の対象領域 / Target Area

- [ ] 公式なでしこ3（cnako v3.7.24）との挙動不一致の解消
- [ ] ネイティブAOTコンパイル（LLVM/LLD）の不具合
- [ ] インタプリタ実行時の不具合
- [ ] CLI / 引数パース / 診断メッセージの不具合
- [ ] OS依存境界（macOS arm64 / Linux x86_64 / Windows x86_64）

## 公式処理系との差分検証 / Oracle Difference Verification

<!--
公式互換機能の修正の場合、公式cnakoとの比較結果や追加した差分fixtureについて記載してください。
-->

- [ ] `tests/fixtures/` または `tests/oracle/` に回帰テスト・差分テストを追加した
- [ ] 公式cnakoとlnakoで同一の出力が得られることを確認した
- [ ] （意図的な挙動差が残る場合）`docs/COMPATIBILITY_QUIRKS.md` に理由と制約を記録した

## 検証チェックリスト / Verification Checklist

- [ ] **コード整形**: `zig build fmt-check` が通る
- [ ] **単体テスト全実行**: `zig build test --summary all` がすべて成功する
- [ ] **互換性台帳・証拠更新**:
  - [ ] `node tools/sync_compat.mjs --check` が通る
  - [ ] （製品変更に伴い必要な場合）`node tools/update_current_evidence.mjs` を実行し、証拠更新コミットを含めた
- [ ] **コミット規律**: 日本語の署名付きコミットを作成した（未検証状態でのコミットやforce pushを行わない）
