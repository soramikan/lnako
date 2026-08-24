# 互換性上の注意事項

この文書は、なでしこ3 v3.7.24（`aa18c7e`）の命令説明だけからは判断しにくい挙動を記録します。
lnakoは、意図的な非互換として合意した項目を除き、説明文ではなく固定した公式実装と差分テストの結果を
互換基準にします。項目を追加するときは、公式実装の場所、lnako側の扱い、差分テストIDを併記します。

## 配列・表・辞書

| 命令 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| `配列挿入` | 元配列へ要素を挿入するが、戻り値は変更後配列ではなく、削除要素0件を表す空配列。内部で `splice(i, 0, s)` の戻り値をそのまま返す | 同じく元配列を変更し、空配列を返す | `plugin-system-array-mutation-quirks` |
| `配列一括挿入` | 元配列を変更し、こちらは変更後の元配列を返す | 同じ | `plugin-system-array-mutation-quirks` |
| `配列削除` | `配列切取`の別名として動き、配列の場合は削除した単一要素を返す | 同じ | `plugin-system-array-mutation-quirks` |
| `配列切取`（辞書） | キーの値がtruthyの場合だけ削除する。値が`0`、空文字列、`false`などの場合はキーを残して`undefined`を返す | 公式互換のため同じ挙動を維持する | `plugin-system-array-mutation-quirks` |
| `配列追加` / `配列プッシュ` | 元配列を変更し、JavaScriptの`push`が返す要素数ではなく、変更後配列を返す | 同じ | `plugin-system-array-mutation-quirks` |
| `配列複製` | JSONの文字列化・再解析による深い複製。循環参照とBigIntは失敗し、`undefined`や関数はJSON規則の影響を受ける | JSON互換の深い複製として扱う | `plugin-system-array-core` |
| `配列足` | 第1引数が配列なら`concat`相当の新配列を返す。配列でなければ第2引数を使わず、第1引数だけをJSON複製する | 同じ | `plugin-system-array-core` |
| `表列数` | 空表でも初期値の`1`を返す | 同じ | `plugin-system-table` |
| `表行列交換` | 行に列がない箇所を空文字列で補う | 同じ | `plugin-system-table` |
| `表右回転` | 行に列がない箇所を補わず`undefined`のまま残す | 同じ | `plugin-system-table` |
| `表曖昧検索` / `表正規表現ピックアップ` | `/式/フラグ`形式ではなく、`RegExp`コンストラクタへ渡す生のパターン文字列を受け取る | 同じ | `plugin-system-table` |
| `表CSV変換` / `CSV変換` / `表TSV変換` / `TSV変換` | 変換結果を返すだけでなく、入力表の各セルを引用処理後の文字列へ置き換える | 公式互換のため入力表も変更する | `plugin-csv-all` |

根拠は固定オラクルの
[`core/src/plugin_system_array.mts`](https://github.com/kujirahand/nadesiko3/blob/3.7.24/core/src/plugin_system_array.mts) と
[`core/src/plugin_system_dict.mts`](https://github.com/kujirahand/nadesiko3/blob/3.7.24/core/src/plugin_system_dict.mts) です。

## 標準出力

| 命令 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| `継続表示` | 直ちには出力せず内部プールへ文字列を追加し、次の`表示`がプールと引数をまとめて1行出力する | 同じ | `plugin-system-stdio` |
| `連続無改行表示` | 可変個引数を結合して`継続表示`へ渡すため、次の`表示`まで出力を保留する | 同じ | `plugin-system-stdio` |
| `言` | 命令本体は文字列だけをロガーへ送るが、公式CLIのstdoutロガーを通すと1行出力になり改行が付く。`表示ログ`には追加しない | CLIで同じ1行出力にする | `plugin-system-stdio` |
| `表示` | 保留中の継続表示を先頭に付けて出力し、改行付きの内容を`表示ログ`へ追記する | 同じ | `plugin-system-stdio` |

根拠は固定オラクルの
[`core/src/plugin_system_stdio.mts`](https://github.com/kujirahand/nadesiko3/blob/3.7.24/core/src/plugin_system_stdio.mts) です。

## 日時と再現性

日時命令は公式カタログ上で`pure`とされていても、`今`、`今日`、`システム時間`などは実時計を読みます。
lnakoは実行結果の互換性とテストの再現性を両立するため、CLIではホストの実時計を使い、テストでは固定した
壁時計を注入します。日時差分テストは`Asia/Tokyo`で実行し、乱数、タイマー、単調時計もホスト抽象化から
差し替えます。

公式CLIの依存モジュール`shell-quote`は、読み込み時に内部識別子生成のため`Math.random`を4回呼びます。
これはなでしこプログラムの乱数ではないため、固定ホストはコンパイラ内部の乱数と同様に別ストリームへ
分離します。分離しない場合、同じソースでも公式CLI経由とAPI経由で最初の`乱数`が変わります。
差分テストIDは`plugin-math-all`です。

## マークアップと漢数字

| 命令 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| `HTML整形`の空行 | `html` 1.0.0のトークン単位出力をそのまま返すため、`head`や`body`の前に挿入する空行にも現在のインデント空白が残る | 2空白インデントだけでなく、空行上の空白も同じバイト列で返す | `plugin-markup-all` |
| `マークダウンHTML変換`の末尾改行 | `marked` 18.0.7は見出し・段落・リストなどの生成HTMLに末尾改行を付けるが、HTMLブロックは入力の改行をそのまま保ち自動追加しない | ブロック種別ごとに同じ末尾規則を使う | `plugin-markup-all` |
| `漢数字` | 小数部の0は`〇`、整数値0は`零`。全角数字と指数表記を先に10進表記へ展開し、先頭の`+` / `-`は漢数字にせず保持する | 同じ前処理、零の字種、ASCII符号を使う | `plugin-kansuji-all` |
| `漢数字`のNumber判定後の変換 | 空文字はJavaScriptの`Number("")`が0なので`零`になる。`.5`、`1.`も受理する。一方、`Infinity`、`0x10`、前後空白もNumber判定は通るが、変換本体は元の文字列を4桁単位で処理し、数字以外を文字列`undefined`へ変換する | Number判定と、その後に続く文字単位変換の不整合まで再現する | `plugin-kansuji-generated` |
| `漢数字`の指数展開 | 正数の指数表記だけを独自展開する。整数部が2桁以上の`10e1`や`01e2`は通常の科学表記より0を1桁多く補って`千`になり、`.5e1`は末尾の小数点を残して`五・`になる。先頭に符号がある`-1e3`は展開せず、`e`を`undefined`として変換する | 正規表現の適用範囲と小数点移動式の境界誤差を含めて固定する | `plugin-kansuji-generated` |
| `算用数字`の非標準表記 | 連続する基本漢数字は10進の桁列ではなく、内部の2要素組を乗算する。そのため`一二万`は20,000、`一二`は0になる | 一般的な漢数字に加え、この組化アルゴリズムも再現する | `plugin-kansuji-all` |
| `算用数字`の大単位 | `万`や`無量大数`のように係数を書かない大単位は1倍ではなく0を返す。`一無量大数`はBigIntを返す | 係数の既定値とNumber/BigInt境界を同じにする | `plugin-kansuji-all` |

## モジュール取り込み

| 構文 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| Windowsの絶対パスを使う`取り込む` | `D:/path/plugin.mjs`のようなドライブ文字付きパスも相対モジュール名として扱い、現在のソースディレクトリを先頭に付ける。このため、存在する絶対パスでも取り込みに失敗する | 利用者の絶対パスは正規化して読み込む。公式オラクル用fixtureは同一ドライブ上に置き、相対パスで取り込んでOS間の比較条件を揃える | `plugin-markup-all`、`plugin-kansuji-all`、`plugin-caniuse-all` |

## QuickJS互換モード

| 命令・API | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| `JSオブジェクト取得` / `sys.__findVar` | Mapにキーが存在するかではなく取得値をtruthy判定する。そのため値が`0`、`false`、空文字列、`null`なら、第2引数の既定値または`null`を返す | 値の型を保持したまま同じtruthy探索を再現する | `compat-js-find-quirks` |
| `sys.__getSysVar`と`sys.__findVar` | `__getSysVar("X")`はシステム変数の非修飾キーだけを調べる。一方`__findVar("X")`はローカル変数と`module__X`を探索するため、同じ名前でも結果が異なる | システム大域表と現在フレーム・モジュール探索を分離する | `compat-js-host` |
| JS構文・呼び出しエラーのCLI終了 | 公式`cnako3`はSyntaxError等をstderrへ出しても終了コード0になる経路がある | lnakoは診断をstderrへ出し、実行失敗を終了コード1で返す。差分テストは双方で失敗が観測できることを検証する | `compat-js-error-eval`、`compat-js-error-function`、`compat-js-error-method` |
| `build --compat-js`の`--emit` | 公式処理系には対応するネイティブ埋め込み出力区分がない | QuickJS対応ランタイムを含む自己完結bundleなので`exe`だけを許可し、`obj` / `llvm-ir`は曖昧な中間生成物を出さず拒否する | `compat-js-plugin-imports` |
| QuickJS本体のReleaseSafe検査 | 上流Cはtagged pointer、callback cast、flexible array、符号付きshift等の低水準表現を使い、Debugでは動いてもZigのC UBSanがmacOS / Windowsでtrapする | ハッシュ固定した上流QuickJS Cだけ`undefined`群と`function`検査を外す。自作bridgeとZigコードはReleaseSafe検査を維持し、3環境で実行テストする | `Differential QuickJS compatibility test`、`Smoke test` |

## ネイティブプラグイン

| 境界 | 分かりにくい挙動 | lnakoの扱い | テストID |
|---|---|---|---|
| `.dylib` / `.so` / `.dll`の`取り込む` | 公式v3.7.24には対応するネイティブABIがなく、JSプラグインとはロード・所有権・スレッド境界が異なる | ソースとして読まず正規化パスをIRへ保持し、`run` / `test`の初期化時に`lnako_plugin_v1`を検証してロードする | `native-plugin-abi` |
| `check`時のネイティブライブラリ | ABI初期化は任意のネイティブコードを実行するため、静的検査との境界が分かりにくい | `check`は拡張子・取り込み構造・動的命令構文までを検査し、ライブラリのロードとABI検証は行わない。欠落・ABI不一致は`run` / `test`で診断する | `native-plugin-open-failure`、`native-plugin-abi-mismatch` |
| ネイティブプラグインを含む`build` | IR実行器では利用できるが、LLVM AOTランタイムにはまだ動的ABI dispatcherがない | 不完全な実行ファイルを生成せず、終了コード2と専用診断で拒否する | `native-plugin-abi-aot-rejection` |
| 厳格モードの外部命令名 | 命令一覧は動的ライブラリの初期化時に登録されるため、意味解析時には確定していない | ネイティブプラグインを直接取り込むモジュールでは未知の「命令」だけを動的解決対象にする。未知の変数は従来どおり診断し、未登録命令は実行時に拒否する | `native-plugin-strict-dynamic-command` |
| 標準命令と同名の登録 | `表示`等は実行器内の専用経路とプラグイン経路で優先順位が異なり、上書きを許すと命令ごとに挙動が変わる | ネイティブ同士の重複に加え、固定した標準cnako命令527件との名前衝突も登録時に拒否する | `ネイティブ命令登録の属性と重複を検証する` |
| opaque値のUTF-8参照 | 任意値を暗黙に文字列化すると、配列・辞書の変更後にキャッシュ済みポインタが古くなる | `get_utf8`は不変なString / BigIntだけを受け付け、他の型は型別getterで明示的に取得する。ポインタはhandle解放まで有効 | `native-plugin-abi` |
| 非同期完了と終了処理 | workerから呼べる関数とtokenの有効期間が通常のhost callbackと異なる | 別スレッドで許可するのは`complete_async`だけ。終了時は`deinitialize`でworkerを停止した後に未完了tokenと命令contextを破棄する | `native-plugin-async-thread` |
| 非WindowsホストからのMSVCクロスビルド | Zig 0.16.0は`x86_64-windows-msvc`向けlibcを非Windows環境へ同梱しないため、C fixtureをリンクできない | ローカルの構文・ABIクロス検査は`x86_64-windows-gnu`で行い、正式なWindows x86_64 MSVCのビルド・実ロード・実行は`windows-2025` CIランナーで検証する | GitHub Actions `Windows x86_64` / `Native plugin ABI test` |

ABI値の所有権と非同期スレッド制約は[`NATIVE_PLUGIN_ABI.md`](NATIVE_PLUGIN_ABI.md)へ分離して記録します。

## 最適化レベル

| 境界 | 分かりにくい挙動 | lnakoの扱い | テストID |
|---|---|---|---|
| `-O0`と`-O1`以上 | Nako SSA最適化とLLVM PassBuilderは別段階であり、単にLLVMの最適化レベルだけが変わるわけではない | `-O0`は元IRと動的変換を維持する。`-O1`以上は独立複製したIRへ型推論・定数伝播・直接呼び出し・DCEを適用し、検証後にLLVMへ渡す | `LLVM C APIで全最適化レベルのモジュールを検証してIRを出力する`、`Differential native AOT test` |
| 関数引数の型推論 | ある静的呼び出しが数値だけを渡していても、同じ関数が関数値や再帰経路から別の型で呼ばれる可能性がある | 関数値として外へ渡る関数は狭めない。再帰を含む全静的呼び出しの実引数型が一致した場合だけ狭める | `関数値として外部へ渡る関数の引数型を狭めない`、`異なる型を渡す再帰呼び出しでは引数型を狭めない` |
| 数値アンボックス | タグ付き値のpayloadを直接`double`として使う処理は、型推論が誤ると動的変換より高速でも意味が変わる | `-O1`以上かつ`number`と証明された演算入力だけ直接取り出す。真偽判定も`number` / `boolean`と証明された場合だけ専用LLVM命令へ下げる | `O1では証明済み数値と真偽判定をアンボックスしO0のIRを変更しない` |
| NaNと符号付きゼロの定数伝播 | `NaN == NaN`は偽だが、最適化器内部では同じNaN事実が収束したかを判定する必要がある。また`+0`と`-0`は除算などで区別できる | 言語の比較演算はJS規則を使い、最適化器の事実同一性だけをbinary64のbit列で判定する。剰余ゼロはNaN、`-0`の剰余は符号を保持する | `定数畳み込みでNaNと符号付きゼロを区別する` |
| 定数分岐先のphi | 条件が定数でも、捨てる辺がphiの唯一の入力なら、辺だけを消すとLLVM IRとして不正な0入力phiになる | その形の分岐は保守的に維持し、後段LLVM最適化へ任せる | `唯一の入力を持つphiへの定数分岐は保守的に維持する` |

全最適化レベルの意味同一性は、公式cnako3、公式生成JavaScript、`lnako run`、AOT `-O0` / `-O1` /
`-O2` / `-O3`の7経路差分テストで確認します。

## Nodeホスト・ファイル・圧縮

| 命令 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| `一時フォルダ作成` | 引数を親フォルダとして扱わず、`fs.mkdtempSync`の接頭辞へそのまま渡す。例えば`work-`ならカレントディレクトリ直下の`work-XXXXXX`を作る。空なら`os.tmpdir()`自体を接頭辞にするため、通常は一時ディレクトリの「中」ではなく同じ親に作る | 同じ接頭辞規則で6文字を付加し、新規ディレクトリを作る | `plugin-node-temporary-directory` |
| `ファイル情報取得` | Nodeの`fs.Stats`を返すため、`isFile`と`isDirectory`は真偽値ではなくメソッド。メソッドだけを変数へ取り出して呼ぶと`this`が失われ、Node内部の`_checkModeProperty`参照で失敗する | メソッドとして公開する。なでしこ構文ではレシーバー付きメソッド呼び出しを直接表せないため、型とフィールド構成を差分検証する | `plugin-node-file-core` |
| `ファイル列挙`（順序） | `fs.readdirSync`が返す順序をそのまま使う。順序はAPI契約上保証されず、ファイルシステムにも依存する | 3正式環境で再現可能にするため名前の昇順へ固定する。各OSでは同じfixtureを公式処理系でも実測する | `plugin-node-file-core` |
| `ファイル列挙`（パターン） | `*`だけのglobではない。`.`と`*`だけを正規表現用に変換し、残りの`[]()+?`などは正規表現として解釈する。また先頭を固定しないため、`a*.txt`は`za.txt`にも一致する | 同じ正規表現生成規則、末尾固定、大文字小文字無視を使う | `plugin-node-file-pattern-regexp` |
| `全ファイル列挙` | 非再帰版と異なり、結果は絶対パス。ディレクトリ自身は含めず、該当ファイルだけを返す | 同じ | `plugin-node-file-core` |
| `ファイルコピーデフォルト動作` | `上書き`、`上書`、`overwrite`のいずれかと完全一致すると、通常の`ファイルコピー`と`ファイル移動`も上書きを許可する。それ以外はコピー先が存在するだけで処理前に失敗する | 同じ3値を認識し、ファイル・ディレクトリのどちらも処理開始前にコピー先を確認する | `plugin-node-file-core` |
| Bufferの暗黙文字列化 | `Buffer.toString()`としてUTF-8復号する。不正列は例外にせずWHATWG UTF-8 decoderの最大部分列単位で`U+FFFD`へ置換する | 同じ。不正な各バイトを機械的に1文字ずつ置換せず、途中で切れた有効な接頭辞は1個の`U+FFFD`にする | `plugin-node-encoding` |
| BufferのJSON変換 | `JSON.stringify(Buffer)`は配列でなく`{"type":"Buffer","data":[...]}`を返す。整形指定時は通常オブジェクトと配列の両方の深さで字下げする | 同じオブジェクト形状と字下げにする | `plugin-node-encoding` |
| `ハッシュ値計算` / `ランダム配列生成`のバイト列 | エンコーディングを省略したハッシュ値は`Buffer`だが、乱数は`Uint8Array`。前者のJSONは`{"type":"Buffer","data":[...]}`、後者は`{"0":値,...}`となる。暗黙文字列化も前者はUTF-8復号、後者は10進値のカンマ区切り | バイト列の種類を内部で保持し、添字・反復は共通化しつつ、JSONと文字列化は種類ごとに同じ規則を使う | `plugin-node-crypto` |
| `ランダム配列生成`の個数 | `NaN`は0件、小数は0方向に切り捨てる。負数は`RangeError`、65,536件超は`crypto.getRandomValues`の`QuotaExceededError`になる | 0〜65,536件を許可し、同じ変換と拒否境界にする | `plugin-node-crypto` |
| 暗号命令の実行時例外と公式CLI終了コード | 公式`cnako3`は乱数個数の`RangeError`などをエラー表示しても、呼び出し経路によってプロセス終了コードが0のままになる | `lnako`は実行時エラーを非0終了にする。差分テストでは、公式側だけはエラー表示も失敗分類として扱う | `plugin-node-crypto` |
| `ハッシュ関数一覧取得` | Node 24がリンクするOpenSSLの`crypto.getHashes()`をそのまま返すため、利用可能な別名と順序はNode/OpenSSLのビルドに依存し得る | 正式3環境のNode 24オラクルで一覧を比較し、一覧中の全名称を5出力形式で検証する | `plugin-node-crypto` |
| `自分IPV6アドレス取得` | link-localアドレスも返すが、OSのscope名（`%en0`など）は戻り値に含めない | OS APIから得たscopeを除去し、公式のアドレス文字列と一致させる | `plugin-node-network-addresses` |
| `自分IPアドレス取得` / `自分IPV6アドレス取得`の対象 | Nodeの`os.networkInterfaces()`はlibuv経由でUPかつRUNNINGのインターフェイスだけを列挙する。Linuxで停止中のDocker bridgeにIPが残っていても結果に入らない | POSIXの`getifaddrs`結果をUP/RUNNINGフラグで絞り、単にアドレスがあるだけの停止インターフェイスは除外する | `plugin-node-network-addresses` |
| 簡易HTTPサーバの未登録URL | callbackにも静的パスにも一致しないURLでは404を送らず、接続を開いたままにする。静的パスに一致した後でファイルがなければ404を返す | 通常の404検証は静的パス内の不存在で行う。未登録URLの接続保留は専用回帰テストで扱う | `plugin-httpserver-all` |
| HTTP callbackの文字列 | `AJAX送信時`、`POST送信時`、`AJAX失敗時`などは文字列から関数を名前解決せず、渡された値を後でそのまま呼ぶ。文字列を渡すと通信完了時に`TypeError`になる | callback値をそのまま保持する。名前付き関数は関数値または`～時には`構文で渡す | `plugin-node-http-callbacks`、`plugin-node-http-onerror` |
| `POSTフォーム送信時`のContent-Type | FormData本文にはboundaryがあるが、公式実装が手動設定する`Content-Type: multipart/form-data`にはboundary引数がない | この命令だけ欠落を再現し、`POSTフォーム送信`と`POSTフォーム保障送信`は正しいboundaryを付ける | `plugin-node-http-callbacks` |
| Promise版HTTP応答 | `AJAX保障送信`などは本文でなく`Response`を返す。暗黙文字列化は`[object Response]`、JSON変換は`{}`で、本文は`AJAX内容取得`により非同期取得する | HTTP応答を専用オブジェクト種別として保持し、同じ文字列化・JSON形状にする | `plugin-node-http-options-and-promises` |
| `AJAXバイナリ取得` | Nodeの`Buffer`や`Uint8Array`でなく`ArrayBuffer`を返す。暗黙文字列化は`[object ArrayBuffer]`、JSON変換は`{}` | バイト内容を保持した専用`ArrayBuffer`種別を返す | `plugin-node-http-async-values` |
| HTTPの`asyncFn`命令 | `POST送信`、`POSTフォーム送信`、`AJAXテキスト取得`、`AJAX_JSON取得`、`AJAXバイナリ取得`は、なでしこ言語側ではPromiseでなくawait済みの値になる | 呼び出しを完了まで待ち、値を直接返す | `plugin-node-http-async-values` |
| Discord送信の戻り値 | `DISCORD送信`と`DISCORDファイル送信`は`asyncFn`だが`return_none`でもあり、文として完了を待つ。戻り値を変数へ代入しようとすると公式コンパイラが拒否する | 文として同期的に完了を待ち、成功時は`undefined`とする | `plugin-node-http-discord`、`plugin-node-http-discord-file` |
| LINE Notify命令 | `LINE送信`と`LINE画像送信`はAPIを呼ばず、2025年4月で利用不能になった旨の例外を常に投げる | 同じく常に失敗させ、外部通信しない | `plugin-node-http-line-message-discontinued`、`plugin-node-http-line-image-discontinued` |
| HTTP callbackの完了順 | 複数のfetchは開始順ではなく実際の通信完了順にcallbackを呼ぶ | ホストワーカーの完了順を採番してメインイベントループでcallbackを実行する | `plugin-node-http-callbacks` |
| 簡易HTTPサーバの本文上限 | POST本文が10MiBを超えると413と`Request entity too large.`を返す。静的ファイルやGETにはこの上限を適用しない | 10MiB超をランタイムへ渡さず、入力を排出してから同じ413応答を返す | `plugin-httpserver-all` |
| `エンコーディング変換`（`hex`） | Nodeの`Buffer.from(S, "hex")`規則に従い、奇数桁の末尾を無視し、最初の非16進文字で変換を打ち切る | 同じ。例えば`4142zz`は`[65,66]`になる | `plugin-node-encoding` |
| `エンコーディング変換`（`base64`） | `iconv-lite`のencoderはUTF-16文字数を4文字境界で本体と端数に分け、それぞれを復号する。このため`QUI=xx`は`[65,66,199]`になる | 同じ分割規則と、空白・非base64文字・URL-safe文字の扱いを実装する | `plugin-node-encoding` |
| `cesu8` | 補助平面文字を通常のUTF-8の4バイト列ではなく、UTF-16のサロゲート各1単位を3バイトずつ、合計6バイトへ変換する。一方、取得時は連続するサロゲートをJS文字列として保持するため表示時には元の1文字へ戻る | UTF-16コード単位ごとのCESU-8変換と、孤立・不正列の置換規則を独立実装する | `plugin-node-encoding-special` |
| `utf7`の`+` | 非direct文字が`+`一文字だけの連続部分なら`+-`になるが、`+&日本`のように他の非direct文字と連続すると`+`も含めて全体がbase64化される | `iconv-lite`と同じ連続部分単位で判断する | `plugin-node-encoding-special` |
| `utf7-imap`の`&` | ASCII範囲はdirect文字だが、`&`だけは`&-`へエスケープする。非direct部分は通常の`/`を`,`へ置き換えたModified Base64になる | 同じdirect範囲、終端、Modified Base64規則で変換する | `plugin-node-encoding-special` |
| `ファイル処理時` / `ファイル処理強制停止` | 進捗の`件数`は再帰走査したファイル数で、ディレクトリ数を含めない。コールバック中に停止すると現在のファイルまではコピー済みになり、移動元は削除しない。次のコピー・移動開始時には停止状態を解除する | 同じ単位と停止境界にする | `plugin-node-file-callbacks` |
| `起動` / `コマンド実行` / `起動時` | 子プロセス完了を待たずに後続文へ進む一方、子プロセスはイベントループを生存させる。完了出力とコールバックは後続文やタイマーの実行中にも処理され、開始順ではなく完了順になる | 子プロセスをホストのワーカースレッドで実行し、完了順序を採番してメインのイベントループへ戻す。ランタイム値とコールバックはワーカースレッドから直接操作しない | `plugin-node-process-order`、`plugin-node-process-completion-order` |
| `起動時`と短い`秒待`の競合 | `秒待`と子プロセスは別々の非同期処理なので、待ち時間内に子プロセスが終わる保証はない。同じ50ms待機でもマシン負荷により、後続の配列表示が`[]`または完了値入りになる | 実用上の完了順は公式と同じにする。差分fixtureでは十分な待機時間を確保し、50ms競合そのものを成功条件に使わない | `plugin-node-process` |
| `ファイルコピー時` / `ファイル移動時` / `ファイル削除時` / `圧縮時` / `解凍時` | 操作を開始すると直ちに後続文へ進み、完了後にコールバックを呼ぶ。後続文から出力ファイルを使う場合はコールバックで連鎖するか待機が必要 | 同じ非同期境界でホスト操作を開始し、完了とコールバックだけをメインのイベントループへ戻す | `plugin-node-file-callbacks`、`plugin-node-native-archive` |
| `圧縮解凍ツールパス` / `圧縮解凍ツールパス変更` | 既定値`7z`を含め、常に指定外部コマンドを呼び出す | 未変更の既定値では内蔵stored-ZIP実装を使う。明示的に変更した後は指定した7-Zip互換コマンドを使う | `plugin-node-native-archive` |

既定ZIPを内蔵するのは、通常モードの実行ファイルを外部7-Zipへ依存させず、Windowsを含む3環境で同じ安全検査を行うためです。
外部ツールを選んだ場合の引数は公式と同じ`a -r` / `x -o... -y`形式です。

## 更新規則

- 説明文と実装が食い違う場合は、固定した公式v3.7.24の実行結果を優先する。
- OS依存挙動は各正式OS上の公式処理系をオラクルにする。
- 互換性を維持するためだけに再現した不自然な挙動は、この文書と回帰fixtureの両方へ残す。
- 公式版を更新するときは各項目を再計測し、挙動が変わった項目を移行記録へ残す。
