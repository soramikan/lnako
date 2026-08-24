# lnako

`lnako` は、日本語プログラミング言語「なでしこ3」のソースをネイティブ実行ファイルへ変換する、Zig製コンパイラです。独自の意味IRとSSA IRを経由してLLVM IRを生成し、LLDでリンクします。

現在は実用版 v1.0.0 に向けて開発中です。互換基準は、なでしこ3 v3.7.24です。未実装機能を動作済みとして扱わず、進捗は `compat/` の機械可読な互換表で公開します。

## 必要なツール

- Zig 0.16.0
- LLVM / LLD 22.1.8
- Node.js 24.x（公式処理系との互換テストだけで使用）
- QuickJS 2026-06-04（`--compat-js` ビルドだけで使用）

macOSではHomebrewのLLVMを `/opt/homebrew/opt/llvm` または `/usr/local/opt/llvm` から検出します。

## ビルド

```sh
zig build
zig build test
zig build run -- --help
```

構文・意味・HIR/SSA中間表現の検査と、SSA IRの直接実行は実装済みです。相対 `.nako3` 取り込みも再帰的に
検査・実行します。エラー時は元ソースのファイル名・行・列、診断コード、該当行を表示し、終了コード1を返します。

ランタイム値層では、JS互換のbinary64、`undefined` / `null` / 真偽値、UTF-16文字列、任意精度BigIntと
それらの変換・演算を実装済みです。配列、挿入順辞書、関数・クロージャと、循環参照を回収する正確な
mark-and-sweep GCも値層へ統合しています。Node 24との差分テストは固定境界値と決定的生成ケースを継続照合します。

```sh
zig build run -- check program.nako3
zig build run -- run program.nako3
zig build run -- test tests/
```

`run` は条件・反復・関数・クロージャ・配列・辞書・例外監視・動的ななでしこ実行をNako SSA IR実行器で処理します。
`test` は単一ファイルまたはディレクトリ以下の `.nako3` を読み、テスト定義を決定的な順序で実行します。LLVM AOT生成は
後続のバックエンド実装まで未対応です。

## CLI

```text
lnako build <file.nako3> -o <output> [-O0|-O1|-O2|-O3] [--compat-js] [--emit exe|obj|llvm-ir]
lnako run <file.nako3> [--compat-js] -- <program arguments>
lnako check <file.nako3>
lnako test <file-or-directory>
lnako compat report
lnako benchmark
```

現時点では `run`、`check`、`test`、ヘルプ、バージョン表示を利用できます。`build`、`compat report`、
`benchmark` は後続のLLVMバックエンド・標準命令・配布実装とともに有効化します。

設計と検証方針は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) と [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) を参照してください。

## ライセンス

MIT License。互換テストで参照するなでしこ3もMIT Licenseです。第三者依存関係は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) に記録します。
