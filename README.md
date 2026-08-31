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

Promiseは明示的な状態機械とFIFOマイクロタスクキューで実装し、Interpreterと純LLVM AOTで`動時`、成功・失敗・処理・終了時の連鎖、
`束`、`AWAIT実行`による完了待機を扱います。Interpreterのタイマーはホスト抽象化された時計を使い、CLIでは実時間、テストでは待たずに進む決定的時計で
`秒待`、単発・周期タイマー、個別・一括停止を検証します。純LLVM AOTでも`秒待`・`秒待機`・`秒逐次待機`の同期待機に加え、
コールバックを伴う単発・周期タイマー、個別停止・一括停止を実行し、生成main（Windowsではwmain）終了前に保留イベントをドレインします。Windows AOTのwmainはwide argvをUTF-16 code unitのままNode定数へ渡し、WTF-16のunpaired surrogateも保持します。現在の標準命令の実装状況は
`compat/v3.7.24/summary.json` と `implemented.json` に記録しています。

`plugin_system` のシステム定数、四則・論理・ビット演算、型変換、文字列・文字種・幅・かな変換、JSON、
正規表現、配列・表・辞書・日時・URL・標準出力・タイマー・特殊実行・デバッグ支援を実装しています。標準命令の実行基盤は純Zigランタイム、
JS固有の4命令は明示的なQuickJS互換モードで動作します。Unicode大小文字テーブルは固定Node 24の
ECMAScript変換から生成してコミットし、正規表現はUTF-16上の内蔵エンジンで量指定、選択、文字クラス、
通常・名前付きキャプチャ、置換参照、分割を扱います。`u`/`v`の基本Unicode code point・property照合と、
`iu`/`iv`のsimple fold照合にも対応します。`v`の基本集合演算にも対応し、文字列property escapeなど残る構文は未実装境界として拒否します。
さらに数学38命令、CSV 7命令、TOML 2命令、
Promise集約の`束`を純Zigで実装しました。Nodeホスト層ではBuffer、UTF-8/16/32、CESU-8、UTF-7、ASCII、Latin-1、
hex/base64、Shift_JIS/EUC-JP、中国語・韓国語・Big5の多バイト8系統と81種の単バイトコードページ、ファイル・パス・
標準入力・子プロセス・終了シグナル・ZIP、ハッシュ・UUID・安全な乱数、HTTPクライアントと簡易HTTPサーバを
実装し、対象116命令をホスト抽象化へ接続しています。また、Markdown/GFM・HTML整形、固定ブラウザ対応表とブラウザ名変換表、任意精度の漢数字変換も
実装しています。公式カタログの標準527 entryは523件が`native`、4件が明示的な`compat-js`、`blocked`は0件です。
一意命令名の実装台帳は496件（`native` 492件、`compat-js` 4件）で、同名異pluginの重複は31組62 entryです。
catalog ID単位で別に扱います。これらの分類・台帳・fixture関連付けと実行証拠の状態は
`compat/v3.7.24/summary.json`、`implemented.json`、`evidence.json`を正本とし、現行の実行証拠は
`verified` 0件、`trace-confirmed-unattested` 277件、`unverified` 250件です。分類やfixtureの存在は、全entryのAOT実行証明を意味しません。
外部ネイティブ拡張向けには、Cの公開ヘッダ、opaque値、sync・async・pure属性、Promise、host callbackを持つ
`lnako_plugin_v1` ABIを実装しています。`lnako run`とLLVM AOT `-O0`〜`-O3`の両方が同じloaderを使い、
AOTではJavaScriptを使わず埋め込みZig Interpreterでhost callbackとPromiseを橋渡しします。

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

AOTのbyte bufferは、Buffer・Uint8Array・ArrayBufferの直接property参照、Bufferの`parent`・`offset`、
標準prototype methodの関数値を解決します。標準prototypeの代表的な`__proto__`・constructor・method値は
prototype familyごとにidentityを共有し、Buffer・Uint8Array・ArrayBufferの`__proto__ = NULL`では標準propertyを
遮断しながら数値添字とown propertyを維持します。custom prototypeの直接property、継承`length`、標準prototypeを
遮断する境界も実装済みです。Bufferから取り出した`slice`関数を後から呼ぶと、公式生成JavaScriptと同じく
receiver未束縛の実行時エラーになります。receiverを保持した成功呼出し、残るprototype methodの実装、property descriptor、
完全なview identityとcustom prototype semanticsは`TODO: aot-byte-buffer-value`に記録し、
`native-system-byte-buffer-direct-properties`、`native-system-byte-buffer-null-prototype`、
`native-system-byte-buffer-method-calls`で境界を比較します。
Nodeの`ファイル名抽出`・`パス抽出`・`絶対パス変換`・`相対パス展開`は、非文字列入力を暗黙に文字列化せず、Node 24の引数ラベルと`TypeError`の`Received`文面へ変換します。nullish・number・boolean・BigInt・Array・Object・function・Buffer・Uint8Array・ArrayBufferを`native-node-path-type-errors`で公式CLI・生成JavaScript・Interpreter・LLVM AOT O0〜O3と比較します。Windows namespace path、特殊なUNC形式、非UTF-8 path値など残る境界は`COMPATIBILITY_QUIRKS.md`のTODOへ分離します。

現段階のAOT対応は、数値・真偽値・null・NULを含むUTF-16文字列・配列と辞書を含む`&`文字列連結、辞書のown/prototypeおよび配列のownカスタム`toString` / `valueOf`を使う文字列・数値hintのToPrimitive、配列カスタムソートの64要素未満のrun判定・binary insertionと64要素以上のV8 TimSort（run stack・gallop・stable merge）の比較順へ接続、幅変換命令の辞書・prototypeカスタム`substring` / `charAt` / `split`呼出し、BigInt定数・加減乗除・剰余・冪乗・シフト・動的値の抽象等価・厳密等価・関係比較・真偽判定、変数・増減文、数値演算・比較、条件・while・後判定・条件分岐、直接関数呼び出しと関数値呼び出し、捕捉ありクロージャ、エラー監視と例外伝播、
表示、文字列・配列・辞書の添字参照・直接表示、配列・辞書の更新・変数や非配列値からの分割宣言、回数・範囲・変数を含む文字列・配列・辞書の反復、動的ソース実行2 entry（`ナデシコ`・`ナデシコ続`。埋め込みZig Interpreterで構文解析・意味解析・SSA検証・実行を行い、AOTのグローバルと`表示ログ`を同期）、数学38 entry（乱数は固定可能なAOTランタイムPRNGへ接続）、日時29 entry（固定可能なAsia/Tokyo壁時計、Unix秒変換、日時文字列・書式・元号・差分・加算・単調時計へ接続）、URL・Base64 5 entry、パス5 entry（拡張子・終端パス処理）、漢数字・算用数字2 entry（指数・全角数字・小数・BigInt変換）、Nodeホスト情報23 entry（OS・CPU・argv由来のコマンドライン定数3件・環境変数取得・一覧取得・カレントディレクトリ取得2 alias・カレントディレクトリ変更2 alias・ファイル／フォルダ存在判定・ファイル情報取得・ホーム／デスクトップ／ドキュメント／テンポラリパス・母艦パス／母艦パス取得・一時フォルダ作成・IPv4/IPv6アドレス列挙）、NodeファイルI/O 4 entry（`開`・`読`・`バイナリ読`・`保存`のテキスト／Buffer読み書き）、Node文字コード8 entry（SJIS/EUC-JPファイルI/O、`SJIS変換`・`SJIS取得`・任意名のエンコーディング変換・取得）、Node標準入力4 entry（`尋`・`文字尋`の行取得、`標準入力全取得`のUTF-8 stdin読み取り、`標準入力取得時`の全行コールバック）、Node HTTP/AJAX状態3 entry（`POSTデータ生成`のURI component変換、`AJAXオプション設定`のグローバル保持、`AJAX失敗時`の`AJAX:ONERROR`保持）、Node暗号4 entry（固定したNode互換ハッシュ名一覧、全52別名のハッシュ値計算、ランダムUUID生成、ランダム配列生成。生ハッシュはBuffer、乱数配列はUint8ArrayとしてAOTのbyte buffer種別へ保持）、Nodeプロセス終了4 entry（終了処理と終了コードのAOT dispatch、`強制終了時`のSIGINT／コンソール制御イベントcallback）、LINE Notify廃止エラー2 entry（Interpreter/AOTとも外部通信せず常に廃止エラーへ接続）、HTTP/AJAX初期定数5 entry（AJAXオプションの空文字とHTTPサーバー4変数の未取り込み時null）、`元号データ`（5件の固定元号表）、caniuseの`対応ブラウザ一覧取得`（16キーのv3.7.24生成データ）と`ブラウザ名変換表`（19キーの生成データ）です。数値の`÷÷`は対応し、BigIntの`÷÷`は公式処理系と同じ実行時エラー経路として扱います。
NodeプロセスのAOT対応には、`起動待機`・`起動`・`コマンド実行`・`コマンド実行待機`・`起動時`のshell実行と完了順callback、および`ブラウザ起動`・`エクスプローラー起動`のOSランチャー委譲を含みます。通常モードではJavaScript runtimeを使わず、`plugin-node-process`、`plugin-node-process-order`、`plugin-node-process-completion-order`、`plugin-node-host-open-external`で公式CLI・生成JavaScript・Interpreter・AOT O0〜O3を比較します。
NodeファイルcallbackのAOT対応には、`ファイルコピー時`・`ファイル移動時`・`ファイル削除時`の完了callback、`ファイル処理時`の再帰ファイル単位の進捗通知、`ファイル処理強制停止`の現在ファイル後停止を含みます。専用`node-file-callback` ABIは、workerがGC値へ直接触れず、完了callbackをAOTイベントドレインで実行します。`plugin-node-file-callbacks`で公式CLI・生成JavaScript・Interpreter・AOT O0〜O3と副作用を比較します。
生成コード用ランタイムABIへ接続した命令には、CSV 7 entry（CSV/TSV解析、引用、数値自動変換、セル文字列化、オプション設定）とTOML 2 entry（TOML解析・表変換、配列テーブル、インライン表、文字列・数値変換）、Markdown/GFM・HTML整形2 entry、一致・不一致2 entry（配列・辞書の内容比較）、表ソート・表数値ソート2 entry（指定列の安定ソート）、敬語6 entry（礼節状態と未定義初期値の公式規則）、標準出力6 entry（出力プール、表示ログ、全引数改行出力）、プラグイン管理3 entry（プラグイン名・名前空間の設定とスタック復元）、システムカタログ6 entry（システム関数一覧・存在確認、プラグイン・モジュール・助詞・予約語一覧）、`ASYNC`（同期実行時のno-op）、Promise 6 entry（`動時`・成功／失敗／処理／終了時の連鎖・`束`）、`AWAIT実行`（Promiseのマイクロタスクとタイマーの完了待機）、`実行時間計測`（関数値・関数名の実行時間）、`デバッグ表示`（位置付きJSON表示）、`ハテナ関数設定`（非JSの関数値・システム命令名配列を保持してcallback列を構築）、`ハテナ関数実行`（設定済みcallback列または既定の`??`を位置付きJSON表示へ接続）、`秒待`・`秒待機`・`秒逐次待機`（ホスト実時間の同期待機）、`秒後`・`秒毎`・`秒タイマー開始時`・`タイマー停止`・`全タイマー停止`（コールバック保持、登録順、終了時ドレイン）、Nodeの`ファイルコピーデフォルト動作`（既定値と代入）、Nodeの基本ファイルI/O 4 entry（`開`・`読`・`バイナリ読`・`保存`のテキスト／Buffer読み書き）、Node文字コード8 entry（SJIS/EUC-JPファイルI/O、`SJIS変換`・`SJIS取得`・任意名のエンコーディング変換・取得）、`ファイルサイズ取得`（statサイズの数値化）、`ファイル情報取得`（stat数値フィールドと`isFile`等のメソッド値生成）、`文字コード変換サポート判定`（Bufferを生成しない正規化・別名判定）、Node標準入力4 entry（`尋`・`文字尋`の行取得、`標準入力全取得`のstdin全体のUTF-8文字列化、`標準入力取得時`の全行コールバック）、`POSTデータ生成`（辞書をURI component形式へ変換）、`AJAXオプション設定`（AJAXオプションの可変グローバル保持）、`AJAX失敗時`（`AJAX:ONERROR`の可変グローバル保持）、`自分IPアドレス`・`自分IPV6アドレス取得`（OS APIによるIPv4/IPv6列挙）、`ハッシュ値計算`（全52別名・5出力形式）、`ランダムUUID生成`（version 4・variant固定）、`ランダム配列生成`（Uint8Arrayの長さ・要素境界）、`圧縮解凍ツールパス`（`7z`既定値）と`圧縮解凍ツールパス変更`（可変グローバル更新）、Node圧縮・解凍4 entry（未変更時はpure-Zig stored-ZIP、明示変更時は指定した7z互換ツール、callbackはAOTイベントドレイン）があります。Node HTTPクライアント19 entry（`AJAX送信時`・`AJAX受信時`・`GET送信時`・`POST送信時`・`POSTフォーム送信時`・`AJAX保障送信`・`HTTP保障取得`・`GET保障送信`・`POST保障送信`・`POSTフォーム保障送信`・`AJAX内容取得`・`AJAX受信`・`POST送信`・`POSTフォーム送信`・`AJAXテキスト取得`・`AJAX_JSON取得`・`AJAXバイナリ取得`・`DISCORD送信`・`DISCORDファイル送信`）は純Zigの`std.http.Client`へ接続し、callback・`対象`更新・Response Promise・ArrayBuffer・フォーム／JSON／バイナリ本文・Discord送信・失敗処理を実装します。AOTのcallbackとPromiseはリクエスト完了結果をイベントキューからメイン実行へ渡し、`AJAX内容取得`はResponse本文またはArrayBufferを返します。`plugin-node-http-callbacks`、`plugin-node-http-options-and-promises`、`plugin-node-http-async-values`、`plugin-node-http-discord`、`plugin-node-http-discord-file`、`plugin-node-http-discord-failure`、`plugin-node-http-onerror`で公式CLI・生成JavaScript・Interpreter・AOT O0〜O3を比較します。`ハテナ関数設定`による非JSのカスタムコールバックはAOTで対応し、`JS:` callbackは明示的な`--compat-js`境界に残します。未対応IRを含む入力は誤変換せず、命令名と元ソース位置付きで拒否します。この列挙は現行AOT routeの範囲であり、互換分類の`native` 523 entryやfixtureの存在は、標準527 entry全件のAOT実行証拠を意味しません。

Node同期ファイル操作8 entry（`ファイル列挙`・`全ファイル列挙`・`フォルダ作成`・`ファイルコピー`・`ファイル上書コピー`・`ファイル移動`・`ファイル上書移動`・`ファイル削除`）は、純Zigの`node-file-operation` ABIへ接続し、glob列挙、再帰コピー／移動、上書き制御、削除を処理します。`native-node-file-operations`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較します。

Nodeの`コンソールクリア`は、比較ハーネスのpipe出力では公式の`console.clear()`が表示内容を変更しないため、純LLVM AOTでは副作用のないno-opとして接続します。`native-node-console-clear`で前後の標準出力を公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3と比較します。

`__DEBUG_BP_WAIT`は、ブレイクポイント一覧・強制待機フラグ・待機フラグ・プラグイン名を専用`debug-breakpoint-wait` ABIへ渡し、純LLVM AOTでも非該当時の即時復帰、メインプラグインの待機解除、非メインプラグインの未解決Promiseを処理します。`native-system-debug-breakpoint-wait`では待機しない非該当経路を公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3と比較します。

Nodeの`尋`と`文字尋`は、純LLVM AOTでも標準入力を一度バッファして行単位に分割し、前者だけ数値変換し、後者は文字列のまま返します。`標準入力取得時`は同じ入力をEOFまで行分割し、各行をシステムグローバル`対象`へ設定して登録コールバックへ同期的に渡します。`native-node-stdin-lines`と`native-node-stdin-callback`でCRLF、プロンプト、後続の`標準入力全取得`、全行コールバックを公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3と比較します。

Node HTTPクライアントの実通信は、`plugin-node-http-callbacks`、`plugin-node-http-options-and-promises`、`plugin-node-http-async-values`、Discord、失敗処理の11ケース・27命令参照をloopbackサーバーで比較し、AOT対象7ケースではO0〜O3も公式CLI・生成JavaScript・Interpreterと比較します。通常モードのAOTはJavaScript runtimeを使わず、ZigのHTTP clientとイベントドレインでcallback・Promise・`対象`更新を実行します。

`plugin-httpserver-all`で扱う簡易HTTPサーバ6 entryは、HTTPクライアントのAJAX命令とは別の純Zig routeです。AOTはlistener、HTTP/1.1 request parser、query/form/multipart、静的ファイル、登録callback、応答header、リダイレクトを実装し、`tools/compare_http_server_aot_oracle.mjs`で公式処理系とO0〜O3を比較します。

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
配布アーカイブ、checksum、SPDX SBOMの生成と検証は[`docs/RELEASE.md`](docs/RELEASE.md)に記載しています。公開用配布物では固定LLVM/LLDを同梱します。
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
