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

構文・意味検査は実装済みです。相対 `.nako3` 取り込みも再帰的に検査します。エラー時は元ソースの
ファイル名・行・列、診断コード、該当行を表示し、終了コード1を返します。

```sh
zig build run -- check program.nako3
```

## CLI

```text
lnako build <file.nako3> -o <output> [-O0|-O1|-O2|-O3] [--compat-js] [--emit exe|obj|llvm-ir]
lnako run <file.nako3> [--compat-js] -- <program arguments>
lnako check <file.nako3>
lnako test <file-or-directory>
lnako compat report
lnako benchmark
```

現時点では `check`、ヘルプ、バージョン表示を利用できます。ほかのサブコマンドは後続の
IR・LLVMバックエンド・ランタイム実装とともに有効化します。

設計と検証方針は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) と [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) を参照してください。

## ライセンス

MIT License。互換テストで参照するなでしこ3もMIT Licenseです。第三者依存関係は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) に記録します。
