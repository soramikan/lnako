# アーキテクチャ

## コンパイルパイプライン

```text
source
  -> prepare / lexer / indentation / DNCL
  -> AST
  -> semantic HIR
  -> Nako SSA IR
  -> LLVM IR
  -> object
  -> LLD
  -> native executable
```

フロントエンド、言語非依存に近いNako IR、LLVMバックエンド、ランタイムを分離します。公式なでしこ3のTypeScript実装を実行時依存にせず、固定バージョンの公式処理系を差分テストのオラクルとして使用します。

## モジュール境界

- `frontend`: 正規化、字句解析、構文変換、AST、診断
- `semantic`: スコープ、命令解決、モジュール、HIR
- `ir`: SSA値、基本ブロック、型情報、検証
- `backend/llvm`: LLVM C API、最適化、TargetMachine
- `runtime`: Value、UTF-16文字列、GC、コレクション、例外、非同期
- `plugins`: 標準命令と `lnako_plugin_v1`
- `cli`: build/run/check/test/compat/benchmark

## フロントエンドの入力規約

- `frontend/source.zig` は改行、全角ASCII、句読点、演算記号を正規化し、文字列とコメントの内容を保持する。
- 正規化後の各UTF-8バイト位置から元入力のバイト位置へ戻せるソースマップを保持する。
- `frontend/lexer.zig` は数値・BigInt・文字列・演算子・予約語と助詞を位置情報付きトークンへ変換する。
- 助詞は最長一致で読み、`raw_josi` と意味上の `josi` を分離する。公式処理系との差分テストは
  `tools/compare_lexer_oracle.mjs` で固定バージョンのTypeScript実装へ直接照合する。

## 互換性の原則

- JavaScriptの `Number` に合わせ、通常数値をIEEE 754 binary64として扱う。
- 文字列操作はUTF-16コード単位を基準にする。
- 通常モードはJSエンジンを含めない。
- JS固有命令は `--compat-js` 指定時だけQuickJSへ接続する。
- 対応していない機能を暗黙に代替せず、互換表と診断に理由を出す。
