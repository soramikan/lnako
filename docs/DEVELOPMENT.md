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
node tools/setup_llvm.mjs
node tools/compare_lexer_oracle.mjs
node tools/compare_syntax_oracle.mjs
node tools/compare_parser_oracle.mjs
node tools/compare_parser_diagnostics_oracle.mjs
node tools/compare_semantic_oracle.mjs
node tools/compare_value_oracle.mjs
node tools/compare_interpreter_oracle.mjs
node tools/generate_unicode_case.mjs --check
node tools/check_plugin_system_coverage.mjs
node tools/compare_plugin_system_oracle.mjs
node tools/compare_native_oracle.mjs
node tools/check_builtin_catalog.mjs
node tools/sync_compat.mjs --check
```

AST差分テストは公式の `core/test/fixtures/parser_corpus.mjs` を直接読み、コメント・空行の保持方式に
左右されない構文フィンガープリントを比較します。ローカル追加ケースは
`tests/oracle/parser-cases.json`、拒否ケースは `tests/oracle/parser-diagnostic-cases.json` に置きます。
実行差分ケースは `tests/oracle/interpreter-cases.json` に置き、公式CLIと `lnako run` の双方で成功することを
必須にします。

AOT差分ケースは `tests/oracle/native-cases.json` に置きます。公式CLIの直接実行と `--compile` 生成物、
`lnako run`、LLVM AOT生成物の4経路を比較します。固定LLVM配布物は `tools/setup_llvm.mjs` が
`toolchain.lock.json` のURLとSHA-256から構築し、CIでは `LNAKO_LLVM_DIR` とアーカイブ内で検出した
`LNAKO_LLVM_LIBRARY` を自動設定します。

標準命令を実装して個別の公式差分テストを追加したら `compat/v3.7.24/implemented.json` にテストIDと理由を記録し、
`node tools/sync_compat.mjs --generate` で分類表と集計を再生成します。固定した公式スナップショット自体を再取得する
`--refresh` とは分離されているため、通常の進捗更新ではネットワークを使用しません。

`src/root.zig` のテストルートは各サブモジュールを明示的に参照します。Zigの遅延解析によりテストが未収集に
ならないよう、`zig build test --summary all` の実行件数も確認してください。

HIRから生成したNako SSA IRは、次の開発用プローブで確認できます。出力前にIR検証も実行されます。

```sh
zig build ir-probe -- $'A=1\nAを表示\n'
```

## コミット

- 機能と対応テストを同じコミットに含める。
- テスト成功後に日本語の署名付きコミットを作る。
- 壊れた中間状態はコミットしない。
- force pushや履歴改変を行わない。

## LLVM探索

ローカルでは `LNAKO_LLVM_LIBRARY`、`LNAKO_LLVM_DIR` を優先し、未指定時はPATH、Homebrew、一般的なLinuxパスの順でLLVM 22.1.8を
探します。見つかった共有ライブラリは `LLVMGetVersion`、Clang/LLDは `--version` で完全な版を検証します。
SDK配布物は対応するLLVM/LLDを同梱し、生成プログラム自体はLLVMやZigに依存しません。
