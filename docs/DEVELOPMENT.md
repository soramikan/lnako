# 開発手順

## 検証順序

1. `zig fmt --check build.zig src`
2. `zig build test`
3. 変更した機能の差分互換テスト
4. マイルストーンでは全互換テストとベンチマーク

公式なでしこ3 v3.7.24との字句解析差分テストは次で実行します。初回だけ固定アーカイブを
SHA-256検証して `.cache/oracle/` に展開し、公式TypeScriptをNode 24でビルドします。

```sh
node tools/setup_oracle.mjs
node tools/compare_lexer_oracle.mjs
node tools/compare_syntax_oracle.mjs
```

## コミット

- 機能と対応テストを同じコミットに含める。
- テスト成功後に日本語の署名付きコミットを作る。
- 壊れた中間状態はコミットしない。
- force pushや履歴改変を行わない。

## LLVM探索

ローカルでは `LLVM_CONFIG` を優先し、未指定時はPATH、Homebrew、一般的なLinuxパスの順でLLVM 22を探します。SDK配布物は対応するLLVM/LLDを同梱し、生成プログラムはそれらに依存しません。
