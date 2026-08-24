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
node tools/setup_quickjs.mjs
node tools/compare_lexer_oracle.mjs
node tools/compare_syntax_oracle.mjs
node tools/compare_parser_oracle.mjs
node tools/compare_parser_diagnostics_oracle.mjs
node tools/compare_semantic_oracle.mjs
node tools/compare_value_oracle.mjs
node tools/compare_interpreter_oracle.mjs
node tools/generate_unicode_case.mjs --check
node tools/update_plugin_system_implemented.mjs --check
node tools/check_plugin_system_coverage.mjs
node tools/check_system_runtime_coverage.mjs
node tools/compare_plugin_system_oracle.mjs
node tools/check_standard_plugin_coverage.mjs
node tools/compare_standard_plugin_oracle.mjs
node tools/compare_supplemental_plugin_oracle.mjs
node tools/check_compat_js_coverage.mjs
node tools/compare_compat_js_oracle.mjs
node tools/check_native_plugin_abi.mjs
node tools/generate_legacy_encoding.mjs --check
node tools/update_node_implemented.mjs --check
node tools/check_node_plugin_coverage.mjs
node tools/compare_node_file_oracle.mjs
node tools/check_encoding_compat.mjs
node tools/compare_node_exit_oracle.mjs
node tools/compare_node_interrupt_oracle.mjs
node tools/check_node_archive_smoke.mjs
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
`lnako run`、LLVM AOT `-O0` / `-O1` / `-O2` / `-O3`生成物の7経路を比較します。固定LLVM配布物は `tools/setup_llvm.mjs` が
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

## QuickJS互換モード

`zig build -Dcompat-js=true`だけがQuickJSを静的リンクします。通常の`zig build`は同じZig APIをC stubへ
接続するため、JSエンジンを含みません。固定ソースは`tools/setup_quickjs.mjs`がURL、SHA-256、`VERSION`、
必須ソース一式を検証します。

QuickJSは`js_realloc_rt(JSRuntime *, ...)`を汎用`DynBuf` callbackへ意図的に型変換します。Zigの
ReleaseSafeが有効にするC関数型sanitizerは、このABI互換呼び出しをmacOS arm64で`SIGTRAP`にします。
また、tagged pointer、flexible array上の`container_of`、符号付きshift等もWindows ReleaseSafeのUBSanに
捕捉されます。このため固定・ハッシュ検証済みのQuickJS本体Cソースに限り`undefined`群と`function`検査を
無効化します。ローカルbridgeを含む他のZig/Cコードの安全検査は維持し、CIでDebugとReleaseSafeの両方を
実行します。

```sh
node tools/setup_quickjs.mjs
zig build -Dcompat-js=true test
node tools/check_compat_js_coverage.mjs
node tools/compare_compat_js_oracle.mjs
```

差分テストは4命令、なでしこ変数・関数との双方向呼び出し、配列・辞書の変更同期、ES moduleの相対依存、
Promise、失敗境界、`build --compat-js`生成物を検証します。通常ビルドと互換ビルドを別々にテストし、
リンク境界の混入も検出します。

## ネイティブプラグインABI

公開Cヘッダとfixtureを使う実ロードテストを、macOS・Linux・Windowsの各CIランナーで実行します。

```sh
zig build native-plugin-fixture
node tools/check_native_plugin_abi.mjs
node tools/check_native_plugin_abi.mjs --release-safe
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe native-plugin-fixture
```

非WindowsホストのZig 0.16.0はMSVC libcを提供しないため、ローカルのWindowsクロス検査にはGNU ABIを
使います。正式対象のMSVC ABIはWindows CIランナー上でビルドと実ロードの両方を検証します。

所有権、スレッド制約、非同期完了、セキュリティ境界は
[`docs/NATIVE_PLUGIN_ABI.md`](NATIVE_PLUGIN_ABI.md)を参照してください。
