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

通常モードの実行ファイルは、Zigで実装した`lnako_runtime`静的ライブラリをLLDでリンクします。ランタイムABIは
UTF-16ヒープ値、配列・挿入順辞書、型付きルートフレーム、子要素を反復走査するmark-and-sweepを持ち、生成LLVM `main` が初期化と
終了処理を必ず呼びます。開発ツリーでは`zig-out/lib/`、配布物ではコンパイラの`../lib/`から解決し、
`LNAKO_AOT_RUNTIME_LIBRARY`で明示パスを指定できます。

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
- `frontend/syntax_transform.zig` は明示インデント構文と行末コロンへ `ここまで` を補い、DNCL/DNCL2の
  代入、整数除算、制御構文、配列初期化、表示命令を標準トークンへ変換する。JSON内の改行は
  ブロック境界として扱わない。
- `frontend/ast.zig` は全ノードに開始・終了位置を持たせ、値、子ノード、関数引数、ループ方向を
  arena所有の共通表現として保持する。意味解析はこのASTをHIRへ変換する。
- `frontend/parser.zig` はPratt式パーサと再帰下降の文・ブロックパーサを組み合わせる。代入、関数、
  条件・反復・例外、配列・辞書・参照、連文、DNCL変換後構文を扱い、公式parser corpus全67件を
  追加ケースとともに `tools/compare_parser_oracle.mjs` で構造照合する。
- 構文エラーは `frontend/diagnostic.zig` の安定した診断コード、元入力のバイト範囲、行・列を持つ。
  `lnako check` と差分診断テストは同じ診断データを使用する。

## 意味解析とモジュール

- `semantic/analyzer.zig` はモジュール・関数スコープを作り、グローバル名を `module__name` へ修飾する。
  関数引数とローカル変数を分離し、公開シンボルの非修飾・修飾参照、厳チェック、重複定義、
  定数再代入、曖昧な取り込みを診断する。
- `semantic/builtin_catalog.zig` は互換表の標準cnako命令527件から生成した索引である。
  `tools/check_builtin_catalog.mjs` が固定カタログとの全件一致をCIで検証する。
- `semantic/module_graph.zig` は相対 `.nako3` を再帰的に読み、同一実体の重複取り込みと循環を抑止する。
  `.js` / `.mjs` は明示的な互換モードなしでは診断し、通常モードのモジュールグラフへ混入させない。
- `.dylib` / `.so` / `.dll`はソースとして読み込まず、正規化したパスをIRのネイティブプラグイン一覧へ渡す。
- `lnako check` はエントリだけでなくモジュールグラフ全体を構文・意味解析する。

## HIRとNako SSA IR

- `ir/hir.zig` は名前解決済みASTを、グローバル・ローカル参照、分割代入、増減、関数、構造化制御を
  明示したHIRへ変換する。元ソース位置、ループ方向、分割代入先、関数引数のシンボルを保持する。
- `ir/lower_ssa.zig` はHIRをSSA値と基本ブロックへ変換する。条件・反復・条件分岐・例外経路には
  明示的な分岐先を持たせ、式の評価順を命令順として固定する。
- `ir/verifier.zig` は基本ブロックID、終端命令、分岐先、SSA値の一意性・定義優位性、phi入力、
  例外分岐先を検証する。不正なIRはLLVMへ渡さない。
- `ir/printer.zig` は回帰テストと調査用の安定したテキスト表現を出力する。この表現は公開ABIではない。
- `lnako check` は構文・意味解析に加えてHIR/SSA生成とIR検証まで実行する。

## 互換性の原則

- JavaScriptの `Number` に合わせ、通常数値をIEEE 754 binary64として扱う。
- 文字列操作はUTF-16コード単位を基準にする。
- 通常モードはJSエンジンを含めない。
- JS固有命令は `--compat-js` 指定時だけQuickJSへ接続する。
- 対応していない機能を暗黙に代替せず、互換表と診断に理由を出す。

## QuickJS互換境界

- `-Dcompat-js=true`のコンパイラだけが固定QuickJSを静的リンクし、通常ビルドは同じC ABIのstubへ接続する。
- `.js` / `.mjs`の静的な相対依存をモジュールグラフへ再帰的に取り込み、QuickJSのES module loaderへ
  メモリ上の固定ソースとして登録する。実行先の元ソースファイルへフォールバック依存しない。
- QuickJS値とNako Valueの間でNumber、BigInt、UTF-16文字列、配列、辞書、関数を変換する。JS由来の
  配列・辞書はQuickJSオブジェクトのidentityを保持し、JS呼び出し前後に変更を双方向同期する。
- `sys.__getSysVar`、`__setSysVar`、`__findVar`、`__findFunc`、`__exec`をホストコールとして接続し、
  なでしこ関数をQuickJSから同期呼び出しできる。
- `build --compat-js`はコンパイラ自身のQuickJS対応ランタイムと検証済みソースグラフを1実行ファイルへ
  埋め込む。起動時は末尾の版付きbundleを検証し、通常のCLI解析へ入らずエントリを実行する。

## ネイティブプラグイン境界

- `include/lnako_plugin_v1.h`をC ABIの正本とし、descriptor、host、registry、commandの全構造体に
  `struct_size`とABI版を持たせる。動的ライブラリは`lnako_plugin_v1`シンボルだけを必須入口にする。
- ランタイム値はopaque handleで渡し、pluginが保持するhandleと非同期PromiseをGCの外部ルートとして追跡する。
- 命令名、助詞、引数範囲、sync・async・pure属性を登録時に検証する。host callbackからなでしこ関数と
  標準命令を同じ実行器上で再入呼び出しできる。
- 非同期完了だけを別スレッドから許可し、atomicなtask境界を通してメインイベントループ上でPromiseを解決する。
  値生成・参照・再入呼び出しはランタイム所有スレッドに限定する。

## 動的な値

- `runtime/string.zig` は文字列をUTF-16コード単位列として保持する。補助平面文字の長さ・添字・部分列は
  ECMAScriptと同じになり、UTF-8出力時だけ孤立サロゲートをU+FFFDへ置換する。
- `runtime/bigint.zig` はZig標準ライブラリの多倍長整数を所有し、10/2/8/16進解析、四則、剰余、累乗、
  符号付きビット演算とシフトを精度損失なしで実行する。
- `runtime/value.zig` は `undefined`、`null`、真偽値、binary64、BigInt、文字列をタグ付き値として表し、
  JS互換の真偽・数値・文字列変換、厳密同値・SameValue・抽象同値を提供する。
- `runtime/operators.zig` はNumberとBigIntの混在を拒否し、Numberのビット演算をToInt32/ToUint32へ正規化する。
  固定ケースと決定的に生成したbinary64ケースを `tools/compare_value_oracle.mjs` でNode 24へ照合する。

## コレクション、関数、GC

- 配列は動的なValue列として伸長、挿入、削除を行い、辞書はUTF-16文字列の内容をキーとする
  `ArrayHashMap` で平均O(1)検索と挿入順列挙を両立する。同値キーの更新では最初の挿入位置を維持する。
- 関数値はIR関数IDまたはネイティブコールバック、引数数、属性、名前付き捕捉値を持つ。ネイティブ呼び出し中は
  関数と全引数を自動的にルートへ登録する。
- ランタイムヒープは全オブジェクトを追跡し、生成コードがValueのアドレスを登録するルートフレームから
  mark-and-sweepを行う。配列・辞書・クロージャを反復的なgrey stackで走査するため、循環参照と深いグラフを
  再帰スタックに依存せず回収できる。GCストレスモードでは各オブジェクト割り当て前に回収を実行する。

## Nako SSA IR実行器

- `runtime/interpreter.zig` は基本ブロックとSSA値を直接実行し、条件分岐、前判定・後判定・回数・範囲・反復、
  `抜ける` / `続ける`、条件分岐、戻り値、例外監視を同じ制御フロー表現で処理する。
- 実行フレームはSSA値、ローカル変数、反復状態、例外ハンドラを保持する。フレーム、グローバル、反復対象は
  GCの外部ルート提供者として走査されるため、実行中の割り当てで回収されない。
- 無名関数はIR関数IDと名前付き捕捉値を持つクロージャへ変換する。動的ななでしこ実行も通常の
  parse → semantic → HIR → SSA → verifyを通し、検証済みIRだけを実行する。
- 出力はホスト抽象化を通す。CLIは標準出力、単体・差分テストはメモリバッファを接続する。
- Promiseは `pending` / `fulfilled` / `rejected` の状態、反応列、FIFOマイクロタスクをランタイムヒープに持ち、
  反応先と未処理タスクもGCで追跡する。実行器は成功・失敗・両方・finallyの反応規則に従って次のPromiseへ伝播する。
- タイマーは単調な論理ミリ秒、登録順を保つ同時刻順序、単発・周期・停止を実行器に持つ。ホストの待機関数を
  CLIでは `std.Io.sleep`、テストでは仮想時計へ接続し、OS時計に依存しない順序テストを可能にする。
- `tools/compare_interpreter_oracle.mjs` は同一の `.nako3` を公式 `cnako3` と `lnako run` へ渡し、
  標準出力、エラー分類、終了コード、シグナルを比較する。

## LLVMバックエンド

- `ir/optimizer.zig` は `-O1` 以上でNako SSA IRの型推論、直接呼び出し解決、定数伝播、定数分岐簡約、
  worklist方式のdead code eliminationを行う。最適化前IRを完全複製してから変更するため、同じ入力から
  `-O0` と最適化済み生成を続けて実行しても元IRは変化しない。
- 引数型は全静的呼び出しの実引数が一致した場合だけ推論する。関数値として外部へ渡る関数、異なる型を
  渡す再帰呼び出し、型が確定しない呼び出しがある場合は `dynamic` を維持する。最適化後はIR verifierを
  再実行し、支配関係、phi入力、直接呼び出し先を含む不整合をLLVMへ渡す前に拒否する。
- `backend/llvm/api.zig` はLLVM 22.1.8のC APIを実行時に読み込み、実バージョンを `LLVMGetVersion` で
  検証する。製品コンパイラをLLVMのZig/C++ ABIへ静的に結合しない。
- `backend/llvm/module.zig` はNako SSA IRからタグ付き動的値を使うLLVM IRを生成する。元ソースの
  `DICompileUnit`、`DIFile`、`DISubprogram`、命令単位の `DILocation` も同時に生成する。`-O1`以上では
  `number` / `boolean` と証明された値だけpayloadを直接取り出し、動的な数値変換・truthy判定を省略する。
- `backend/llvm/compiler.zig` はIR解析、最適化前後のモジュール検証、PassBuilder、TargetMachineを順に
  実行する。`--emit llvm-ir|obj|exe` は同一の検証済みモジュールを入力とする。
- 実行ファイル生成では一時オブジェクトを厳密なパスへ出力し、Clang 22.1.8へLLD 22.1.8の絶対パスを
  `--ld-path` で渡す。リンク後は一時オブジェクトを削除する。
- 現在の生成対象外opcodeは事前検査で元ソース位置とともに拒否する。ヒープ値とホスト命令は後続の
  ランタイムABI実装で順次この許可集合へ加える。
- `tools/compare_native_oracle.mjs` は同じ入力を公式CLI、公式生成済みJavaScript＋Node、`lnako run`、
  `lnako build` の実行ファイルという4経路で実行し、標準出力・エラー分類・終了コード・シグナルを照合する。

## plugin_system標準命令

- `plugins/system` は定数、共通変換、数値・論理・ビット、型、文字列、JSON、正規表現を分割実装する。
  実行器固有の副作用を持つ `二進表示`、`切取`、`範囲切取`、正規表現キャプチャだけをInterpreterが仲介する。
- 文字列はUTF-16で保持しつつ、公式実装が `Array.from` を使う文字数・検索・部分抽出はUnicode scalar単位で扱う。
  ECMAScript大小文字変換は `tools/generate_unicode_case.mjs` がNode 24.15.0から生成した固定テーブルを使い、
  複数文字への写像と文脈依存のGreek final sigmaも処理する。
- JSONは挿入順辞書を保ち、非有限数、`undefined`、関数、Promise、重複キー、孤立サロゲート、循環参照を
  ECMAScriptの `JSON.stringify` / `JSON.parse` 規則へ合わせる。循環参照とBigIntは明示エラーにする。
- 正規表現は外部共有ライブラリへ依存しないUTF-16バックトラッキングエンジンで、選択、グループ、量指定、
  文字クラス、アンカー、フラグ、後方参照、通常・名前付きキャプチャ、置換参照と分割を提供する。
- `tests/oracle/plugin-system-cases.json` は対象20カテゴリと追加パス5命令、計274命令を重複なく列挙する。
  `tests/oracle/system-runtime-cases.json` は礼節・特殊実行・デバッグ支援・プラグイン管理の33命令を列挙する。
  `tools/check_plugin_system_coverage.mjs` が公式カタログ・互換台帳・テストIDを照合し、
  `tools/check_system_runtime_coverage.mjs` が実行器固有命令を同様に照合する。
  `tools/compare_plugin_system_oracle.mjs` が同じソースを公式cnako3と `lnako run` で実行する。

## 数学・CSV・TOML・Promise標準命令

- `plugins/math.zig` はbinary64演算とホスト注入乱数で`plugin_math`の38命令を実装する。
- `plugins/csv.zig` はInterpreter単位のCSV設定を保持し、CSV/TSVの解析、引用、数値自動変換を実装する。
- `plugins/toml.zig` は外部ランタイムへ依存せず、TOMLの表、配列テーブル、文字列、数値、配列、インライン表を扱う。
- Promiseの`束`は入力PromiseをFIFOマイクロタスクへ接続し、入力順の成功配列、空入力、最初の失敗を`Promise.all`と同じ順序で処理する。
- `tests/oracle/standard-plugin-cases.json` が48命令を重複なく列挙し、カバレッジ検査と公式CLI差分テストを3環境CIで実行する。
