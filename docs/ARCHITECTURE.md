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
UTF-16ヒープ値、配列・挿入順辞書、コレクションを保持するイテレーター、型付きルートフレーム、子要素を反復走査するmark-and-sweepを持ち、生成LLVM `main` が初期化と
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

- `frontend/source.zig` は改行、全角ASCII、句読点、演算記号を正規化する。文字列とコメント内も
  CRLF / CRをLFへ正規化するが、全角文字や記号は変換せず保持する。
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
- 関数値はIR関数IDまたはネイティブコールバック、引数数、属性、名前付き捕捉を持つ。IRクロージャは
  GC管理の可変セルを外側フレームと共有し、内側だけが参照する自由変数も中間クロージャが中継する。
  AOTの統一コールバックABIは関数オブジェクトをコンテキストとして受け、捕捉セルを同じローカル値ポインタへ復元する。ネイティブコールバックは必要に応じて値を直接捕捉する。
  ネイティブ呼び出し中は関数と全引数を自動的にルートへ登録する。
- ランタイムヒープは全オブジェクトを追跡し、生成コードがValueのアドレスを登録するルートフレームから
  mark-and-sweepを行う。配列・辞書・クロージャを反復的なgrey stackで走査するため、循環参照と深いグラフを
  再帰スタックに依存せず回収できる。GCストレスモードでは各オブジェクト割り当て前に回収を実行する。

## Nako SSA IR実行器

- `runtime/interpreter.zig` は基本ブロックとSSA値を直接実行し、条件分岐、前判定・後判定・回数・範囲・反復、
  `抜ける` / `続ける`、条件分岐、戻り値、例外監視を同じ制御フロー表現で処理する。
- 実行フレームはSSA値、ローカル変数、反復状態、例外ハンドラを保持する。フレーム、グローバル、反復対象は
  GCの外部ルート提供者として走査されるため、実行中の割り当てで回収されない。
- 無名関数はIR関数IDと名前付き共有セルを持つクロージャへ変換する。関数値の動的呼び出しでは公式同様に
  実引数の末尾へGCルート付きの共有システム文脈を加え、不足引数の残りを`undefined`で補い、超過分を無視する。
  動的ななでしこ実行も通常のparse → semantic → HIR → SSA → verifyを通し、検証済みIRだけを実行する。
- 出力はホスト抽象化を通す。CLIは標準出力、単体・差分テストはメモリバッファを接続する。
- Promiseは `pending` / `fulfilled` / `rejected` の状態、反応列、FIFOマイクロタスクをランタイムヒープに持ち、
  反応先と未処理タスクもGCで追跡する。実行器は成功・失敗・両方・finallyの反応規則に従って次のPromiseへ伝播する。
  純LLVM AOTも同じ状態機械をRuntime内へ持ち、resolve/reject関数と`束`の要素handlerをGC管理の関数値として生成する。
  `AWAIT実行`と生成main終了前のイベントドレインは、Promiseマイクロタスクとタイマーを同じFIFO境界で処理する。
- タイマーは単調な論理ミリ秒、登録順を保つ同時刻順序、単発・周期・停止を実行器に持つ。Interpreterは仮想時計と
  イベントループで処理し、純LLVM AOTはRuntime内のキューとコールバック値を保持してホストの `std.Io.sleep` へ接続する。
  生成mainはグローバルルートを外す前に保留イベントをドレインし、OS時計に依存しないInterpreterの順序テストと、AOTの実時間実行を分離する。
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
  `エラー発生`はthrow値と静的な例外分岐先へ下げる。呼び出し先の未処理throw、二項演算、`null` / `undefined`への添字代入の実行時失敗はGCルート付きの保留例外として返し、各処理後に分割した基本ブロックから最内側ハンドラへ渡して`エラーメッセージ`を設定する。
- `runtime/aot_builtin.zig` はAOT対応済み標準命令の正式名・別名を安定した数値IDへ解決する。LLVM生成物は
  共通の標準命令ABIへ引数列とIDを渡し、ランタイム側で同じタグ付き値・GC・例外機構を使う。現在この経路で
  `文字列変換` / `TOSTR`、`変数型確認` / `TYPEOF`、整数・実数変換、2種類のNaN判定、16進・2進・任意基数変換、
  `RGB`、32bit・BigIntビット演算、基本算術・比較・集約・論理・範囲、空コレクション・真偽判定、多相`掛`、
  Unicode文字数・検索・先頭末尾判定、配列・辞書・UTF-16要素数、parseFloat・BigInt・JavaScript加算を使い分ける
  `足`・`合計`・`連続加算`命令の各正式名と別名、および数学38 entry（乱数を含む）、日時29 entry（現在時刻・日付・年月・曜日・Unix秒・日時文字列・書式・元号・差分・加算・単調時計）、URL・Base64 5 entry、パス5 entry（拡張子・終端パス処理）、漢数字・算用数字2 entry（指数・全角数字・小数・BigInt変換）、Nodeホスト情報23 entry（OS・CPU・argv由来のコマンドライン定数3件・環境変数取得・一覧取得・カレントディレクトリ取得2 alias・カレントディレクトリ変更2 alias・ファイル／フォルダ存在判定・ファイル情報取得・ホーム／デスクトップ／ドキュメント／テンポラリパス・母艦パス／母艦パス取得・一時フォルダ作成・IPv4/IPv6アドレス列挙）、NodeファイルI/O 4 entry（`開`・`読`・`バイナリ読`・`保存`のテキスト／Buffer読み書き）、Node文字コード8 entry（SJIS/EUC-JPファイルI/O、`SJIS変換`・`SJIS取得`・任意名のエンコーディング変換・取得）、Nodeプロセス終了3 entry、LINE Notify廃止エラー2 entry、`元号データ`の固定5件、caniuseの`対応ブラウザ一覧取得`と`ブラウザ名変換表`を実装し、後続命令を個別ABIの増殖なしに追加できる。副作用命令の`二進表示`は同じ変換結果を
  改行付きで出力して`undefined`を返す。CSV 7 entry（CSV/TSV解析、引用、数値自動変換、セル文字列化、オプション設定）も
  `runtime/aot.zig`の`AotCsvState`と同じ標準命令ABIで処理する。TOML 2 entryも同じABIに接続し、
  AOT固有のparser・table writerで配列テーブルとインライン表を処理する。
- `runtime/system_constant.zig` はインタープリタとAOTで共有するシステム定数表を持つ。AOTは実際に参照された
  真偽値、数値、`NaN`、無限大、`null`、`undefined`をLLVMグローバルのタグ付き値へ初期化する。文字列は
  UTF-16定数データから、グローバルのGCルート登録後かつ利用者コードの実行前にヒープ値として生成する。
  Nodeの`AJAXオプション`初期空文字と、HTTPサーバープラグイン未取り込み時の`HTTPメソッド`・`GETデータ`・
  `POSTデータ`・`FILESデータ`の`null`も同じ表で初期化する。CLI Interpreterは`plugin_httpserver`の明示取り込み時だけ
  その4値をサーバー状態へ登録し、通常の`lnako run`では公式CLIと同じ未登録境界を保つ。
  `抽出文字列`と`__DEBUGブレイクポイント一覧`も、同じ境界で独立した空配列として生成する。`元号データ`は公式と同じ元号名・改元日を持つ5件の配列・辞書として生成し、同一Runtime内のグローバル値をGCルートとして保持する。caniuseの`ブラウザ名変換表`は、公式生成データをUTF-16キー・値の挿入順辞書として構築し、同一Runtime内のグローバル値をGCルートとして保持する。argv由来のNode定数は生成`main`の`argc`/`argv`を専用ABIへ渡し、参照されたグローバルをroot登録後に配列・文字列として初期化する。`デスクトップ`、`マイドキュメント`、`テンポラリフォルダ`の暗黙グローバルもOS環境値から専用ABIで初期化する。`母艦パス`と`母艦パス取得`は生成mainがソースパスを専用ABIへ渡し、実行時CWD基準で絶対化した親ディレクトリを共有する。WindowsのWTF-8 argv変換は`TODO: aot-node-windows-wtf8-argv`として別境界に残す。
- `backend/llvm/compiler.zig` はIR解析、最適化前後のモジュール検証、PassBuilder、TargetMachineを順に
  実行する。`--emit llvm-ir|obj|exe` は同一の検証済みモジュールを入力とする。
- 実行ファイル生成では一時オブジェクトを厳密なパスへ出力し、Clang 22.1.8へLLD 22.1.8の絶対パスを
  `--ld-path` で渡す。リンク後は一時オブジェクトを削除する。
- 現在の生成対象外opcodeは事前検査で元ソース位置とともに拒否する。ヒープ値とホスト命令は後続の
  ランタイムABI実装で順次この許可集合へ加える。
- `tools/compare_native_oracle.mjs` は同じ入力を公式CLI、公式生成済みJavaScript＋Node、`lnako run`、
  `lnako build` の実行ファイルという4経路で実行し、標準出力・エラー分類・終了コード・シグナルを照合する。
  dispatch traceではlowering時に決めたsite IDをInterpreter/AOTで共有し、AOTはattempt/resultをcall IDで対にする。

## plugin_system標準命令

- `plugins/system` は定数、共通変換、数値・論理・ビット、型、文字列、JSON、正規表現を分割実装する。
  実行器固有の副作用を持つ `二進表示`、`切取`、`範囲切取`、正規表現キャプチャだけをInterpreterが仲介する。
- 文字列はUTF-16で保持しつつ、公式実装が `Array.from` を使う文字数・検索・部分抽出はUnicode scalar単位で扱う。
  ECMAScript大小文字変換は `tools/generate_unicode_case.mjs` がNode 24.15.0から生成した固定テーブルを使い、
  複数文字への写像と文脈依存のGreek final sigmaも処理する。
- インタープリタのJSON命令は、非有限数、`undefined`、関数、Promise、重複キー、孤立サロゲート、循環参照を
  ECMAScriptの `JSON.stringify` / `JSON.parse` 規則へ合わせる。canonical array indexの辞書キー順と
  BigInt・循環・不正JSONの実行時文言は`docs/COMPATIBILITY_QUIRKS.md`に固定する。JSONエンコード5命令は純LLVM
  AOTへ接続する。デコード3命令は、インタープリタとAOTでUTF-16コード単位を直接読む
  明示スタックパーサーを使い、孤立サロゲートと深いネストでCスタックとUTF-8変換に依存しない。不正JSONの
  診断messageもUTF-16コード単位Valueとして保持し、Node 24の長文source窓・生の制御文字・引用符表示を再現する。
- 正規表現は外部共有ライブラリへ依存しないUTF-16バックトラッキングエンジンで、選択、グループ、量指定、
  文字クラス、アンカー、フラグ、後方参照、通常・名前付きキャプチャ、置換参照と分割を提供する。
- `tests/oracle/plugin-system-cases.json` は対象20カテゴリと追加パス5命令、計274命令を重複なく列挙する。
  `tests/oracle/system-runtime-cases.json` は礼節・特殊実行・デバッグ支援・プラグイン管理の33命令を列挙する。
  `tools/check_plugin_system_coverage.mjs` がインタープリタの全命令列挙、必須境界fixture、互換台帳の
  `native` / `blocked`を照合する。ここでの`native`件数は台帳値であり、AOT差分テスト自体は
  `tests/oracle/native-cases.json`と`tools/compare_native_oracle.mjs`が検証する。
  `tools/check_system_runtime_coverage.mjs` が実行器固有命令を同様に照合する。
  `tools/compare_plugin_system_oracle.mjs` が同じソースを公式cnako3と `lnako run` で実行する。

## 数学・CSV・TOML・マークアップ・比較・表・Promise標準命令

- `plugins/math.zig` はbinary64演算とホスト注入乱数で`plugin_math`の38命令を実装する。
- `plugins/csv.zig` はInterpreter単位のCSV設定を保持し、CSV/TSVの解析、引用、数値自動変換を実装する。AOTは`runtime/aot.zig`の`AotCsvState`と共通builtin dispatchで同じ7 entryを処理し、`native-csv-commands`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- `plugins/toml.zig` は外部ランタイムへ依存せず、TOMLの表、配列テーブル、文字列、数値、配列、インライン表を扱う。AOTも同じ値境界を`runtime/aot.zig`で実装し、`native-toml-commands`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- `plugins/markup.zig` はMarkdown/GFMのブロック・インライン変換とHTML整形を純Zigで実装する。AOTは共通UTF-8変換関数を`runtime/aot.zig`から呼び出し、`native-markup-commands`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- `plugins/system/math.zig` の`一致`/`不一致`は配列・辞書を再帰的に内容比較し、スカラーはstrict equalityへ委譲する。AOTは`Comparison.deep_equal`/`deep_not_equal`へ接続し、`native-system-deep-comparison`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。QuickJS互換モードは対象外である。
- `plugins/system/arrays.zig` の`表ソート`/`表数値ソート`は指定列の行propertyを文字列順・数値順で比較し、元表を安定・破壊的に更新する。AOTは`table_sort`/`table_numeric_sort` dispatchへ接続し、`native-system-table-sort`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。疎配列・複雑な行property境界は未fixtureである。
- `plugins/system` の敬語6命令は、未定義相当の礼節レベル、`拝啓`によるリセット、`敬具`による加点、3つの加算別名、取得時のfalsey正規化を共有する。AOTは`courtesy_increment`/`courtesy_begin`/`courtesy_end`/`courtesy_level` dispatchへ接続し、`native-system-courtesy`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- `plugins/system` の標準出力6命令は、単一値の出力プール、可変引数の連結、表示ログのクリア、全引数の改行出力を共有する。AOTはdirect-displayと`stdio_*` dispatchへ接続し、`native-system-stdio`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- `plugins/system` のプラグイン管理3命令は、文字列化したプラグイン名・名前空間の設定と、両方を対で保存・復元するスタック操作を共有する。AOTは`lnako_aot_plugin_management_call`とGC追跡対象の名前空間スタックへ接続し、`native-system-plugin-management`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- `plugins/system` の`ASYNC`は同期実行時に値を返さないno-opである。AOTは`async_noop` builtin dispatchへ接続し、`native-system-async`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。Promiseを待機する`AWAIT実行`は別のcore Promise境界としてAOTへ接続する。
- `plugin_promise` の`動時`・`成功時`・`処理時`・`失敗時`・`終了時`・`束`は、専用の`promise` dispatch routeで状態遷移、反応連鎖、入力順の束ねを処理する。`native-system-promise-success`、`native-system-promise-reject-process-finally`、`native-system-promise-reject`、`native-system-promise-bundle`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較し、`native-system-promise-timer-await`で`AWAIT実行`とタイマーの連動を比較する。
- `plugins/system` の`実行時間計測`は、関数名を解決して関数値を実行し、公式の`performance.now()`相当の経過ミリ秒を返す。AOTは名前解決・関数値呼び出しを`system_measure_time` builtinへ接続し、固定可能な単調時計で`native-system-measure-time`の公式7経路差分を検証する。
- `plugins/system` の`ハテナ関数実行`は、カスタムコールバックが未設定の既定`??`動作を`デバッグ表示`と同じ位置付きJSON出力へ接続する。AOTは専用`hatena-default` ABIと`native-system-hatena-default`で公式7経路差分を検証する。`ハテナ関数設定`の任意関数・`JS:`コールバックは通常AOTへ持ち込まず、`TODO: aot-hatena-custom-callback`として残す。
- `plugins/system` の`__DEBUG_BP_WAIT`は、ブレイクポイント一覧・強制待機フラグ・待機フラグ・プラグイン名を専用`debug-breakpoint-wait` ABIへ渡す。AOTでも非該当時は行番号を即時返し、メインプラグインの該当時はマーカー出力後に待機フラグが立つまで待機し、メイン以外の該当時は未解決Promiseを返す。`native-system-debug-breakpoint-wait`で非該当の公式7経路差分を検証する。
- `plugins/system` のシステムカタログ6命令は、標準関数名478件、既定プラグイン7件、公開助詞、公開予約語を固定順序で配列化し、存在確認は公式と同じ最後の引数を調べる。AOTは共通builtin dispatchとGCルート付き配列生成へ接続し、`native-system-catalog-lists`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。利用者関数一覧の`グローバル関数一覧取得`はInterpreter側の境界として残る。
- Node/AJAXの初期定数5 entryは、`native-node-http-initial-constants`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。HTTPサーバーの実通信は`plugin-httpserver-all`で別に検証し、AOTのHTTPサーバー実装済みとは扱わない。
- Nodeの`LINE送信` / `LINE画像送信`は廃止済みAPIを呼び出さず、InterpreterとAOTの両方で同じ廃止エラーへ接続する。公式CLIはstdoutへ表示して終了コード0、公式生成JavaScriptは実行時エラーで終了コード1になる既知の経路差があるため、`native-node-line-message-discontinued` / `native-node-line-image-discontinued`は公式生成JavaScriptをoracleにする。QuickJS互換モードはこの標準命令の証拠経路に含めない。
- Nodeの`存在` / `フォルダ存在`は、Nodeの`fs.statSync`相当でパスの存在とディレクトリ種別を判定する。InterpreterはNode hostのstat抽象へ、AOTはJS runtimeを使わず`std.Io.Dir.statFile`へ接続し、未存在・stat失敗はfalseとして返す。`native-node-file-existence`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較し、QuickJS互換モードは対象外とする。
- Nodeの`開` / `読` / `バイナリ読` / `保存`は、テキストをUTF-8 lossily読み書きし、`バイナリ読`とBuffer入力の`保存`ではバイト列を保持する。純LLVM AOTは`std.Io.Dir.cwd().readFileAlloc` / `writeFile`へ接続し、読み取り上限を1 GiBとして`byte_buffer`とUTF-16文字列を生成する。`native-node-file-io`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較し、QuickJS互換モードは対象外とする。
- Nodeの`ファイル列挙` / `全ファイル列挙` / `フォルダ作成` / `ファイルコピー` / `ファイル上書コピー` / `ファイル移動` / `ファイル上書移動` / `ファイル削除`は、専用の`node-file-operation` ABIで純Zig AOTへ接続する。列挙は`.`・`*`・`;`の公式パターン変換、末尾固定、大文字小文字無視、名前の昇順を共有し、`全ファイル列挙`は再帰walkerで絶対パスのファイルだけを返す。コピー・移動は再帰ディレクトリ、`make_path`、削除を処理し、通常命令は可変な`ファイルコピーデフォルト動作`をABI経由で参照、上書き命令は常に上書きする。`native-node-file-operations`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較し、QuickJS互換モードは対象外とする。
- Nodeの`コンソールクリア`は、公式がTTYでない標準出力では実質的に出力を変更しないため、AOTでは副作用のないno-opとして接続する。`native-node-console-clear`で前後の標準出力を公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3と比較し、QuickJS互換モードは対象外とする。
- Nodeの`母艦パス` / `母艦パス取得`は、ソースパスを実行時CWD基準で絶対化した親ディレクトリを共有する。AOTは生成mainから専用ABIへソースパスを渡し、Interpreterと同じ規則で直接グローバルと関数を初期化する。`native-node-mother-path`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- Nodeの`一時フォルダ作成`は、引数を親フォルダではなく接頭辞として扱い、6文字の英数字suffixを付けて新規ディレクトリを作る。純LLVM AOTは`std.Io.Dir`で作成し、既存名の衝突時は再試行する。`native-node-temporary-directory`で2回生成・存在判定・suffix長を公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3と比較する。
- Nodeの`自分IPアドレス取得` / `自分IPV6アドレス取得`は、Nodeの`os.networkInterfaces()`相当のOS列挙を使い、IPv4/IPv6アドレスだけを順序付き配列へ変換する。純LLVM AOTはPOSIXの`getifaddrs`またはWindowsの`GetAdaptersAddresses`を直接呼び、IPv6のinterface scopeを除去する。`native-node-network-addresses`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- Nodeの`ファイルコピーデフォルト動作`は、`上書禁止`を初期値とする可変システムグローバルである。純LLVM AOTの専用`node-file-operation` ABIはこのグローバルを明示的に受け取り、`上書き`・`上書`・`overwrite`との完全一致だけを通常のコピー・移動の上書き許可として扱う。上書き命令は常に上書きする。`native-node-file-copy-default`でグローバル状態を、`native-node-file-operations`で実際のコピー・移動・削除・列挙を公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3と比較する。
- Nodeの`ファイルサイズ取得`は、指定pathを`std.Io.Dir.statFile`でstatし、`size`をbinary64へ変換する。stat失敗は実行時エラーとして伝播する。`native-node-file-size`で`.`の公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- Nodeの`ファイル情報取得`は、指定pathのstatから`size`、時刻、inode、リンク数、block sizeを数値フィールドとして生成し、`isFile`・`isDirectory`などを名前付きメソッド関数値として辞書へ格納する。純LLVM AOTは`std.Io.Dir.statFile`とGC管理のメソッド値を使い、グローバル関数一覧へ登録せずに同じフィールド構成を返す。`native-node-file-info`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。
- Nodeの文字コード8 entryは、InterpreterとAOTが共有する純Zig codecを使う。正規化・別名解決・生成済みlegacy/single-byte表に加えて、`SJIS変換`・`SJIS取得`・任意名の`エンコーディング変換`・`エンコーディング取得`、SJIS/EUC-JPファイルI/Oを同じUTF-16／Buffer境界へ接続し、AOTは`node-encoding`／`node-file-encoding` routeで処理する。`native-node-encoding`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較し、`native-node-encoding-support`ではbooleanのサポート判定を分離して比較する。
- Nodeの`標準入力全取得`は、標準入力を一度だけUTF-8バイト列として読み、UTF-16文字列へ変換する。純LLVM AOTはJS runtimeを使わず`std.Io.File.stdin`から同じ入力を読み、`native-node-stdin-all`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。`尋`・`文字尋`・`標準入力取得時`の行分割・コールバックは別の未実装境界である。
- Nodeの`POSTデータ生成`は、辞書の挿入順を保ったままキーと値をUTF-8へ変換し、URI component形式の`key=value&...`文字列を生成する。純LLVM AOTはNode/JavaScriptへ依存せず同じunreserved文字集合とUTF-8バイト単位のパーセントエンコードを使い、`native-node-http-post-data`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。実際のHTTP送信とPromise/callback経路は別の未実装境界である。
- Nodeの`AJAXオプション設定`は、設定値を`AJAXオプション`グローバルへ保持し、戻り値を持たない。純LLVM AOTは専用ABIで同じグローバルへ値を直接保存し、`native-node-http-options-set`で設定後の辞書を公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3と比較する。実際のHTTP送信とPromise/callback経路は別の未実装境界である。
- Nodeの`AJAX失敗時`は、失敗時コールバック値を`AJAX:ONERROR`グローバルへ保持し、戻り値を持たない。純LLVM AOTは専用ABIで関数値を同じGC管理グローバルへ保存し、`native-node-http-onerror-set`で設定後の型を公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3と比較する。実際のHTTP失敗時callback呼び出しとPromise/callback経路は別の未実装境界である。
- Nodeの`圧縮解凍ツールパス`は`7z`を初期値とする可変システムグローバルで、`圧縮解凍ツールパス変更`はその値を更新する。純LLVM AOTは共有システム定数と専用`archive-tool-path` ABIでこの状態遷移を保持し、`native-node-archive-tool-path`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較する。外部7z実行を含む`圧縮`・`解凍`本体は`TODO: aot-node-archive-operations`として別境界に残す。
- Nodeの暗号4命令は、Node 24/OpenSSL互換の固定52名称、全別名のハッシュ計算、version 4 UUID、Uint8Array乱数配列を提供する。純LLVM AOTは`crypto.calculateDigest`を共有し、ハッシュの生値を`buffer`、乱数配列を`uint8_array`、将来のArrayBuffer値を`array_buffer`としてGC管理する。添字・長さ・反復・ToPrimitive・JSON形状も種別ごとに保持し、`native-node-hash-names`と`native-node-crypto`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3と比較する。Bufferのslice/view identity、継承プロパティ、バイト列のown property列挙・削除は別の未実装境界として追跡する。
- Promiseの`束`は入力PromiseをFIFOマイクロタスクへ接続し、入力順の成功配列、空入力、最初の失敗を`Promise.all`と同じ順序で処理する。`native-system-promise-bundle`で空入力と失敗伝播も固定する。
- `tests/oracle/standard-plugin-cases.json` が48命令を重複なく列挙し、カバレッジ検査と公式CLI差分テストを3環境CIで実行する。
