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

QuickJS互換ビルドは、固定アーカイブを検証してから明示的に有効化します。通常ビルドにはJSエンジンを
リンクしません。

```sh
node tools/setup_quickjs.mjs
zig build -Dcompat-js=true
zig build -Dcompat-js=true test
```

## ビルド

```sh
zig build
zig build test
zig build run -- --help
```

構文・意味・HIR/SSA中間表現の検査と、SSA IRの直接実行は実装済みです。相対 `.nako3` 取り込みも再帰的に
検査・実行します。エラー時は元ソースのファイル名・行・列、診断コード、該当行を表示し、終了コード1を返します。

ランタイム値層では、JS互換のbinary64、`undefined` / `null` / 真偽値、UTF-16文字列、任意精度BigIntと
文字列・配列・辞書のNumber変換を含むそれらの演算を実装済みです。配列、挿入順辞書、関数・クロージャと、循環参照を回収する正確な
mark-and-sweep GCも値層へ統合しています。Node 24との差分テストは固定境界値と決定的生成ケースを継続照合します。

Promiseは明示的な状態機械とFIFOマイクロタスクキューで実装し、`動時`、成功・失敗・処理・終了時の連鎖と`束`を
扱います。Interpreterのタイマーはホスト抽象化された時計を使い、CLIでは実時間、テストでは待たずに進む決定的時計で
`秒待`、単発・周期タイマー、個別・一括停止を検証します。純LLVM AOTでは`秒待`・`秒待機`・`秒逐次待機`の同期待機を
実装し、コールバックを伴う単発・周期タイマーはInterpreter経路に限定しています。現在の標準命令の実装状況は
`compat/v3.7.24/summary.json` と `implemented.json` に記録しています。

`plugin_system` のシステム定数、四則・論理・ビット演算、型変換、文字列・文字種・幅・かな変換、JSON、
正規表現、配列・表・辞書・日時・URL・標準出力・タイマー・特殊実行・デバッグ支援を実装しています。318命令は純Zigランタイム、
JS固有の4命令は明示的なQuickJS互換モードで動作します。Unicode大小文字テーブルは固定Node 24の
ECMAScript変換から生成してコミットし、正規表現はUTF-16上の内蔵エンジンで量指定、選択、文字クラス、
通常・名前付きキャプチャ、置換参照、分割を扱います。さらに数学38命令、CSV 7命令、TOML 2命令、
Promise集約の`束`を純Zigで実装しました。Nodeホスト層ではBuffer、UTF-8/16/32、CESU-8、UTF-7、ASCII、Latin-1、
hex/base64、Shift_JIS/EUC-JP、中国語・韓国語・Big5の多バイト8系統と81種の単バイトコードページ、ファイル・パス・
標準入力・子プロセス・終了シグナル・ZIP、ハッシュ・UUID・安全な乱数、HTTPクライアントと簡易HTTPサーバを
実装し、対象116命令をホスト抽象化へ接続しています。また、Markdown/GFM・HTML整形、固定ブラウザ対応表とブラウザ名変換表、任意精度の漢数字変換も
実装しています。公式カタログの標準527 entryは523件が`native`、4件が明示的な`compat-js`、`blocked`は0件です。
一意命令名の実装台帳は496件（`native` 492件、`compat-js` 4件）で、同名異pluginの重複は31組62 entryです。
catalog ID単位で別に扱います。これらの分類・台帳・fixture関連付けと実行証拠の状態は
`compat/v3.7.24/summary.json`、`implemented.json`、`evidence.json`を正本とし、現行の実行証拠は
`verified` 0件、`trace-confirmed-unattested` 4件、`unverified` 523件です。分類やfixtureの存在は、全entryのAOT実行証明を意味しません。
外部ネイティブ拡張向けには、Cの公開ヘッダ、opaque値、sync・async・pure属性、Promise、host callbackを持つ
`lnako_plugin_v1` ABIを実装しています。

```sh
zig build run -- check program.nako3
zig build run -- run program.nako3
zig build run -- test tests/
zig build run -- build program.nako3 -o program -O2
zig build run -- build program.nako3 -o program.o -O2 --emit obj
zig build run -- build program.nako3 -o program.ll -O2 --emit llvm-ir
zig build -Dcompat-js=true run -- run program.nako3 --compat-js
zig build -Dcompat-js=true run -- build program.nako3 -o program --compat-js
```

`run` は条件・反復・関数・クロージャ・配列・辞書・例外監視・動的ななでしこ実行、Promise・タイマーをNako SSA IR実行器で処理します。
`test` は単一ファイルまたはディレクトリ以下の `.nako3` を読み、テスト定義を決定的な順序で実行します。
`build` はLLVM 22.1.8 C APIで生成IRを検証し、PassBuilderの `default<O0>` ～ `default<O3>`、
TargetMachineによるオブジェクト生成、LLD 22.1.8によるリンクを行います。生成物には元 `.nako3` の
ファイル・行・列に対応するデバッグメタデータを保持します。`-O1`以上ではLLVMのPassBuilderへ渡す前に、
独立複製したNako SSA IRへ型推論、定数伝播、直接呼び出し、dead code eliminationを適用し、証明済みの
数値・真偽値をアンボックスします。`-O0`は元IRを変更せず、動的変換を維持します。
生成実行ファイルにはZig製のJS非依存AOTランタイム静的ライブラリをリンクし、UTF-16ヒープ値と
型付きルートによるmark-and-sweepのライフサイクルを初期化します。実行先にZigやLLVMは不要です。

現段階のAOT対応は、数値・真偽値・null・NULを含むUTF-16文字列・配列と辞書を含む`&`文字列連結・BigInt定数・加減乗除・剰余・冪乗・シフト・動的値の抽象等価・厳密等価・関係比較・真偽判定、変数・増減文、数値演算・比較、条件・while・後判定・条件分岐、直接関数呼び出しと関数値呼び出し、捕捉ありクロージャ、エラー監視と例外伝播、
表示、文字列・配列・辞書の添字参照・直接表示、配列・辞書の更新・変数や非配列値からの分割宣言、回数・範囲・変数を含む文字列・配列・辞書の反復、数学38 entry（乱数は固定可能なAOTランタイムPRNGへ接続）、日時29 entry（固定可能なAsia/Tokyo壁時計、Unix秒変換、日時文字列・書式・元号・差分・加算・単調時計へ接続）、URL・Base64 5 entry、パス5 entry（拡張子・終端パス処理）、漢数字・算用数字2 entry（指数・全角数字・小数・BigInt変換）、Nodeホスト情報20 entry（OS・CPU・argv由来のコマンドライン定数3件・環境変数取得・一覧取得・カレントディレクトリ取得2 alias・カレントディレクトリ変更2 alias・ファイル／フォルダ存在判定・ホーム／デスクトップ／ドキュメント／テンポラリパス・母艦パス／母艦パス取得・一時フォルダ作成）、Nodeプロセス終了3 entry（終了処理と終了コードのAOT dispatch）、LINE Notify廃止エラー2 entry（Interpreter/AOTとも外部通信せず常に廃止エラーへ接続）、HTTP/AJAX初期定数5 entry（AJAXオプションの空文字とHTTPサーバー4変数の未取り込み時null）、`元号データ`（5件の固定元号表）、caniuseの`対応ブラウザ一覧取得`（16キーのv3.7.24生成データ）と`ブラウザ名変換表`（19キーの生成データ）です。数値の`÷÷`は対応し、BigIntの`÷÷`は公式処理系と同じ実行時エラー経路として扱います。
生成コード用ランタイムABIへ接続した命令には、CSV 7 entry（CSV/TSV解析、引用、数値自動変換、セル文字列化、オプション設定）とTOML 2 entry（TOML解析・表変換、配列テーブル、インライン表、文字列・数値変換）、Markdown/GFM・HTML整形2 entry、一致・不一致2 entry（配列・辞書の内容比較）、表ソート・表数値ソート2 entry（指定列の安定ソート）、敬語6 entry（礼節状態と未定義初期値の公式規則）、標準出力6 entry（出力プール、表示ログ、全引数改行出力）、プラグイン管理3 entry（プラグイン名・名前空間の設定とスタック復元）、システムカタログ6 entry（システム関数一覧・存在確認、プラグイン・モジュール・助詞・予約語一覧）、`ASYNC`（同期実行時のno-op）、`実行時間計測`（関数値・関数名の実行時間）、`デバッグ表示`（位置付きJSON表示）、`秒待`・`秒待機`・`秒逐次待機`（ホスト実時間の同期待機）、Nodeの`ファイルコピーデフォルト動作`（既定値と代入）があります。未対応IRを含む入力は誤変換せず、命令名と元ソース位置付きで拒否します。この列挙は現行AOT routeの範囲であり、互換分類の`native` 523 entryやfixtureの存在は、標準527 entry全件のAOT実行証拠を意味しません。

## CLI

```text
lnako build <file.nako3> -o <output> [-O0|-O1|-O2|-O3] [--compat-js] [--emit exe|obj|llvm-ir]
lnako run <file.nako3> [--compat-js] -- <program arguments>
lnako check <file.nako3>
lnako test <file-or-directory>
lnako compat report
lnako benchmark
```

現時点では `build`、`run`、`check`、`test`、`compat report`、`benchmark`、ヘルプ、バージョン表示を利用できます。
`compat report`はビルド時の正本`compat/v3.7.24/summary.json`を機械可読JSONで出力します。
`benchmark`は固定suiteをInterpreter、LLVM O2コンパイル、AOT実行の3経路で計測し、各sampleの期待stdoutを確認したうえで
JSONとMarkdownへ保存します。既定の出力先は`benchmarks/results/latest.json`と`benchmarks/results/latest.md`です。
`--iterations`、`--warmup`、`--suite`、`--output`、`--markdown`で計測条件と出力先を指定できます。
`run --compat-js` はQuickJS 2026-06-04で
4つのJS命令とESモジュール形式プラグインを実行します。`build --compat-js` は検証済みのなでしこ・JSソースを
QuickJS対応ランタイムへ埋め込み、元ソース、Zig、LLVMを実行先で要求しない単一実行ファイルを生成します。
互換生成物はランタイムを内包するため`--emit exe`専用です。

ネイティブプラグインの作成方法と所有権規則は
[docs/NATIVE_PLUGIN_ABI.md](docs/NATIVE_PLUGIN_ABI.md)を参照してください。

設計と検証方針は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) と [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) を参照してください。
命令ごとのfixture関連付けと、実行証拠ではないことの境界は
[docs/COMPATIBILITY_EVIDENCE.md](docs/COMPATIBILITY_EVIDENCE.md) に記録します。
公式実装の説明だけでは分かりにくい戻り値、破壊的変更、出力プールなどは
[docs/COMPATIBILITY_QUIRKS.md](docs/COMPATIBILITY_QUIRKS.md) に差分テストID付きで記録します。

## ライセンス

MIT License。互換テストで参照するなでしこ3もMIT Licenseです。第三者依存関係は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) に記録します。
