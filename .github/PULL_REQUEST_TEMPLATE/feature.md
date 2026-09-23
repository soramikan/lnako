<!--
新機能・機能改善に関するPRテンプレートです。
-->

## 関連Issue / Related Issue

- Closes #

## 機能の概要 / Feature Summary

<!-- 追加した機能、改善した仕様の概要を記載してください -->

## 設計の背景と仕様 / Design & Rationale

<!--
- なぜこの設計・APIを選択したか
- 既存の構文や型システム、SSA IR / LLVM バックエンドへの影響
- （独自拡張の場合）他言語や公式なでしこ3との境界
-->

## 実行経路への対応状況 / Execution Path Support

- [ ] インタプリタ実行 (`lnako run`)
- [ ] ネイティブAOTコンパイル (`lnako build`)
- [ ] 構文・意味検査 (`lnako check`)
- [ ] （該当する場合）QuickJS互換モード (`--compat-js`)

## ドキュメントの更新 / Documentation Updates

- [ ] `README.md` または `docs/` 配下の該当ドキュメントを更新した
- [ ] 日本語の「」や（）を含む文にMarkdownの二重アスタリスク強調を使っていない

## 検証チェックリスト / Verification Checklist

- [ ] **単体テスト**: 新規機能に対する単体テストを追加し、`zig build test --summary all` が成功する
- [ ] **Interpreter/AOT一致**: インタプリタとネイティブAOTで挙動が一致することを単体テストで保証した
- [ ] **コード整形**: `zig build fmt-check` が通る
- [ ] **ソース構造検査**: `node tools/check_source_structure.mjs` がエラーなく通る
- [ ] **署名付きコミット**: 日本語の署名付きコミット（`git commit -S`）を作成した
- [ ] **ランタイム分離**: 通常モードへJSランタイムを混入させていない
