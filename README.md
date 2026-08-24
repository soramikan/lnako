# lnako

`lnako` は、日本語プログラミング言語「なでしこ3」のソースをネイティブ実行ファイルへ変換する、Zig製コンパイラです。独自の意味IRとSSA IRを経由してLLVM IRを生成し、LLDでリンクします。

現在は実用版 v1.0.0 に向けて開発中です。互換基準は、なでしこ3 v3.7.24です。未実装機能を動作済みとして扱わず、進捗は `compat/` の機械可読な互換表で公開します。

## 必要なツール

- Zig 0.16.0
- LLVM / LLD 22.1.8
- Node.js 24.x（公式処理系との互換テストだけで使用）
- QuickJS 2026-06-04（`--compat-js` ビルドだけで使用）

`node tools/setup_llvm.mjs` は `toolchain.lock.json` のOS別アーカイブをストリーミング取得し、SHA-256を
検証して `.cache/toolchains/` へ展開します。CIはこの固定配布物だけを使います。手動配置したLLVMを使う場合は
配布ルートを `LNAKO_LLVM_DIR` に指定できます。共有ライブラリが標準位置にない配布物では
`LNAKO_LLVM_LIBRARY` にファイル自体を指定できます。セットアップスクリプトとCIはアーカイブ内を検査して両方を自動設定します。
macOSではHomebrewのLLVM/LLD 22.1.8も検出します。

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

Promiseは明示的な状態機械とFIFOマイクロタスクキューで実装し、`動時`、成功・失敗・処理・終了時の連鎖と`束`を
扱います。タイマーはホスト抽象化された時計を使い、CLIでは実時間、テストでは待たずに進む決定的時計で
`秒待`、単発・周期タイマー、個別・一括停止を検証します。現在の標準命令の実装状況は
`compat/v3.7.24/summary.json` と `implemented.json` に記録しています。

`plugin_system` のシステム定数、四則・論理・ビット演算、型変換、文字列・文字種・幅・かな変換、JSON、
正規表現、配列・表・辞書・日時・URL・標準出力・タイマーの275命令をZigランタイムへ実装しています。Unicode大小文字テーブルは固定Node 24の
ECMAScript変換から生成してコミットし、正規表現はUTF-16上の内蔵エンジンで量指定、選択、文字クラス、
通常・名前付きキャプチャ、置換参照、分割を扱います。さらに数学38命令、CSV 7命令、TOML 2命令、
Promise集約の`束`を純Zigで実装しました。Nodeホスト層ではBuffer、UTF-8/16/32、CESU-8、UTF-7、ASCII、Latin-1、
hex/base64、Shift_JIS/EUC-JP、中国語・韓国語・Big5の多バイト8系統と81種の単バイトコードページ、ファイル・パス・
標準入力・子プロセス・終了シグナル・ZIP、ハッシュ・UUID・安全な乱数、HTTPクライアントと簡易HTTPサーバを
実装し、対象116命令をホスト抽象化へ接続しています。また、Markdown/GFM・HTML整形、固定ブラウザ対応表、任意精度の漢数字変換も
実装しています。公式カタログ上は482/527命令がnativeで、各命令を公式差分または副作用を隔離したホストテストへ対応付けています。

```sh
zig build run -- check program.nako3
zig build run -- run program.nako3
zig build run -- test tests/
zig build run -- build program.nako3 -o program -O2
zig build run -- build program.nako3 -o program.o -O2 --emit obj
zig build run -- build program.nako3 -o program.ll -O2 --emit llvm-ir
```

`run` は条件・反復・関数・クロージャ・配列・辞書・例外監視・動的ななでしこ実行、Promise・タイマーをNako SSA IR実行器で処理します。
`test` は単一ファイルまたはディレクトリ以下の `.nako3` を読み、テスト定義を決定的な順序で実行します。
`build` はLLVM 22.1.8 C APIで生成IRを検証し、PassBuilderの `default<O0>` ～ `default<O3>`、
TargetMachineによるオブジェクト生成、LLD 22.1.8によるリンクを行います。生成物には元 `.nako3` の
ファイル・行・列に対応するデバッグメタデータを保持します。

現段階のAOT対応は、数値・真偽値・null・文字列定数、変数、数値演算・比較、条件・while、直接関数呼び出し、
表示です。配列、辞書、BigInt、クロージャ、例外、非同期、残りの標準命令は後続の固定マイルストーンで
生成コード用ランタイムABIへ接続します。未対応IRを含む入力は誤変換せず、命令名と元ソース位置付きで拒否します。

## CLI

```text
lnako build <file.nako3> -o <output> [-O0|-O1|-O2|-O3] [--compat-js] [--emit exe|obj|llvm-ir]
lnako run <file.nako3> [--compat-js] -- <program arguments>
lnako check <file.nako3>
lnako test <file-or-directory>
lnako compat report
lnako benchmark
```

現時点では `build`、`run`、`check`、`test`、ヘルプ、バージョン表示を利用できます。`compat report` と
`benchmark` は後続の標準命令・性能記録実装とともに有効化します。`build --compat-js` はQuickJSを実装する
マイルストーンまで明示的に拒否します。

設計と検証方針は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) と [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) を参照してください。
公式実装の説明だけでは分かりにくい戻り値、破壊的変更、出力プールなどは
[docs/COMPATIBILITY_QUIRKS.md](docs/COMPATIBILITY_QUIRKS.md) に差分テストID付きで記録します。

## ライセンス

MIT License。互換テストで参照するなでしこ3もMIT Licenseです。第三者依存関係は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) に記録します。
