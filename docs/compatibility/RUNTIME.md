# Runtime・値のquirks

対象はJSON、値変換、文字列、配列・表・辞書、BigInt、正規表現、Promise、日時・TOMLです。命令の分類と証拠状態は [`../COMPATIBILITY.md`](../COMPATIBILITY.md) を参照してください。

## JSON

- 公式実測・source根拠: `JSON.stringify(undefined)` と関数値はトップレベルでは `undefined`、配列要素では `null`になります。BigIntと循環参照は実行時エラーです。JSON property keyはECMAScriptのarray index昇順と文字列keyの挿入順になります。
- lnakoの現在動作: Interpreter/AOTで同じnullish・関数・BigInt・循環・key順を処理し、UTF-16 code unitを保持します。長い不正入力ではNode 24相当の位置付き診断を生成します。
- 判定: 仕様
- 対象経路: Interpreter / AOT
- 差分テストID: `plugin-system-json-ecmascript-boundaries`、`plugin-system-json-utf16-boundaries`、`native-system-json-encode`、`native-system-json-decode-errors`
- TODO識別子: なし

## JSONの孤立surrogateと深い入力

- 公式実測・source根拠: `JSON.parse("\"\\ud800\"")` は受理され、UTF-16 code unitを保持します。深い入力の受理深度はNode実装・stack条件に依存し、固定仕様値ではありません。
- lnakoの現在動作: high/low surrogateとpairを保持し、parserはC stackへ再帰せず明示stackで深い配列・辞書を処理します。UTF-8出力時だけ孤立surrogateを置換します。
- 判定: 仕様（UTF-16）／意図的制限（安全な非再帰実装）
- 対象経路: Interpreter / AOT
- 差分テストID: `native-system-json-decode-errors`、`JSONデコードは100000段のネストをCスタックなしで処理する`
- TODO識別子: なし

## 配列のholeとproperty

- 公式実測・source根拠: 配列のindex削除はholeになり、holeは `indexOf` などで未定義値とは区別されます。`length` は削除できず、`for...in`・`in`・`slice`・`concat` はpresenceとprototypeを別々に扱います。
- lnakoの現在動作: Interpreter/AOTでhole、明示的 `undefined`、own property、挿入順を区別します。成功経路で扱わない表命令の疎配列や完全なprototype継承は、推測で埋めません。
- 判定: 仕様／未実装境界の分離
- 対象経路: Interpreter / AOT
- 差分テストID: `native-system-array-sparse-presence`、`native-system-array-sparse-copy-reference-concat`、`native-system-array-own-properties`
- TODO識別子: `TODO: sparse-array-presence`

## 辞書・配列のToPrimitive

- 公式実測・source根拠: 文字列hintでは `toString`→`valueOf`、数値hintでは `valueOf`→`toString` を試し、primitiveを返したmethodを採用します。両方がobjectなら `Cannot convert object to primitive value` になります。
- lnakoの現在動作: own propertyとprototype propertyをhint順に調べ、Interpreter/AOTの関数値をreceiver付きで実行します。通常モードはJavaScript runtimeへfallbackしません。
- 判定: 仕様。receiver副作用順序の未検証部分は未実装
- 対象経路: Interpreter / AOT
- 差分テストID: `native-system-dictionary-to-primitive`、`native-system-array-to-primitive`、`native-system-object-to-primitive-host-properties`
- TODO識別子: `TODO: aot-object-to-primitive`、`TODO: aot-function-string-name`

## 表の継承propertyと疎配列

- 公式実測・source根拠: 表命令は行の `slice`、添字、`length`、正規表現、prototype propertyを通常のJavaScript値として参照します。疎な最上位配列、nullish行、継承propertyでは、単純な二重配列処理と異なるエラー・presenceになります。
- lnakoの現在動作: 標準propertyと代表的なbyte buffer rowを処理し、hole・nullish・BigInt混在を個別fixtureで固定します。custom prototypeと全表命令の継承semanticsは完成扱いにしません。
- 判定: 未実装境界
- 対象経路: Interpreter / AOT
- 差分テストID: `native-system-table-sparse-length-errors`、`native-system-table-inherited-properties`、`native-system-table-regexp-sparse-hole`
- TODO識別子: `TODO: table-inherited-properties`、`TODO: sparse-array-presence`

## 連続表示・連続無改行表示のnullish連結

- 公式実測・source根拠: `連続表示` / `連続無改行表示` は全引数を `Array.join('')` 相当で連結するため、`undefined` と `null` の要素は空文字になります。単一引数の `表示` / `継続表示` は `undefined` を文字列 `"undefined"` として表示するため、挙動が異なります。DNCLモードでは `を表示` が `連続表示` へ変換されるため、配列の範囲外読取を表示するDNCLプログラムで差が出ます。
- lnakoの現在動作: Interpreter・AOTの `連続表示` / `連続無改行表示` で `undefined` / `null` を空文字として連結し、`表示` / `継続表示` は従来どおり `"undefined"` / `"null"` を表示します。
- 判定: 仕様
- 対象経路: Interpreter / AOT
- 差分テストID: `display-many-undefined-null`、`dncl-v1-array-oor-read`、`native-display-many-undefined-null`、`native-dncl-v1-array-oor-read`（`compare_interpreter_oracle.mjs`、`compare_native_oracle.mjs`）
- TODO識別子: なし

## 正規表現のUnicodeとエラー

- 公式実測・source根拠: `u`/`v`ではcode point単位、property escape、simple fold、zero-width量指定を扱います。不正escape・capture名・量指定はV8の `Invalid regular expression` 系診断になります。
- lnakoの現在動作: Interpreter/AOTで共有UTF-16エンジンと生成済みUnicode property表を使います。基本的な `u`/`v`集合演算と代表的なエラーは実装しますが、未対応の文字列property、複雑なbacktracking、完全なJSエラー文言は拒否またはTODOとして分離します。
- 判定: 仕様／未実装境界
- 対象経路: Interpreter / AOT
- 差分テストID: `native-system-regexp-unicode-properties`、`native-system-regexp-unicode-ignore-case`、`native-system-regexp-unicode-v-basic`、`native-system-regexp-backtracking-boundaries`、`native-system-regexp-invalid-pattern-error`
- TODO識別子: `TODO: regexp-unicode-flags`、`TODO: regexp-js-error-text`、`TODO: regexp-backtracking-edge`

## BigIntと数値

- 公式実測・source根拠: BigIntとNumberの暗黙混在はエラーになり、BigIntの除算・剰余・比較はNumberと異なる型規則を持ちます。JSON化や数値変換にも専用エラーがあります。
- lnakoの現在動作: BigIntをbinary64から分離し、加減乗除、剰余、冪乗、shift、比較、真偽判定、混在エラーをInterpreter/AOTで保持します。BigIntを勝手にNumberへ丸めません。
- 判定: 仕様
- 対象経路: Interpreter / AOT
- 差分テストID: `native-bigint-arithmetic-and-comparison`、`native-number-and-bigint-shifts`、`native-system-table-numeric-sort-bigint-error`、`native-system-table-numeric-sort-mixed-bigint-error`
- TODO識別子: なし

## Promise・timer・日時

- 公式実測・source根拠: Promise callbackはFIFOのmicrotaskとして処理され、timer・終了待機・例外監視との順序が単純な同期呼出しと異なります。日時は壁時計とUnix秒、Asia/Tokyo、書式・元号の境界を持ちます。
- lnakoの現在動作: Promise state machine、FIFO microtask、仮想時計、timer drainをInterpreter/AOTへ接続し、テストでは決定的時計を使います。実時間やOS依存値をfixtureへ直接埋め込みません。
- 判定: 仕様／再現性のための意図的制限
- 対象経路: Interpreter / AOT
- 差分テストID: `native-system-promise-success`、`native-system-promise-reject-process-finally`、`native-system-promise-bundle`、`native-system-promise-timer-await`、`native-system-timer-wait`、`native-system-timers`、`plugin-system-datetime`
- TODO識別子: 日時の未検証境界はfixture単位で追加

## TOMLの依存ライブラリ境界

- 公式実測・source根拠: 公式 `TOML取得` / `TOML変換` は `smol-toml` へ委譲し、Date系値・配列table・inline table・コメントを扱います。時刻単独のoffset入力では、依存側の壊れた正規化結果が観測されます。standalone生成JavaScriptはplugin登録不足で失敗する場合があります。
- lnakoの現在動作: 正常な日付・時刻・local/offset datetimeは専用値として処理します。時刻単独の非標準入力を公式の壊れた出力へ固定せず、公式CLIをsource oracleとしてroute差を記録します。
- 判定: 公式バグ候補／意図的制限
- 対象経路: Interpreter / AOT（QuickJS対象外）
- 差分テストID: `native-toml-temporal-values`、`native-toml-imported-generated-route`、`toml-temporal-probe`
- TODO識別子: `TODO: toml-temporal-values`、`TODO: catalog-plugin-toml-generated-registration`

## 関数本体内の裸名解決と定義位置

- 公式実測・source根拠: 公式コード生成（`nako_gen.mts`）は単一パスで、関数本体内の裸名は関数定義より前に宣言されたモジュール変数だけを修飾名 `main__X`（`__varslist[2]`）へ解決します。定義位置より後に宣言されたモジュール変数・未宣言名は関数ローカル `__vars` へ解決され、同名の後続モジュール変数とは別物になります。関数名は `__varslist[1]` の実行時解決で位置に依らず、システム定数は `__v0` 参照です。DNCLモード・通常モードとも同じ規則で、無名関数にも適用されます。
- lnakoの現在動作: semantic analyzer が関数定義位置を記録し、関数スコープ内からモジュール変数への解決を「シンボル宣言位置 < 関数定義位置」で制限します。フィルタされた名前・未解決名は関数ローカルへ宣言します（システム定数は除く）。モジュールスコープの検索は qualified_name キーで行うため、ソース中に書かれた修飾名（`mod__A`）は同じ規則で `A` と同一変数へ解決され、取り込み・公開設定に関わらず全モジュールのモジュール変数へ一致します。可視シンボルに一致しない修飾名は、関数内では関数ローカル、モジュールレベルでは生名キーのグローバルへ束縛されます。裸名は公式 `findVar` の `modList` 検索と同様に「エントリ→展開マーカー位置順」の全モジュールを先勝ちで検索します（`symbol.shadowed`/`isDeclSiteSymbol` で宣言文自身のシンボルを除外し、使用位置より後の宣言を不可視にします）。これにより推移的取り込みのモジュール変数や、取り込み先コードからエントリ変数への代入も公式通り解決されます。Interpreter・AOT 共通の解決です。
- 判定: 仕様
- 対象経路: Interpreter / AOT
- 差分テストID: `scope-named-fn-late-module-var`、`scope-anon-fn-late-module-var`、`dncl-v1-scope-late-module-var`、`scopequalreadlate`、`scopequalreadearly`、`scopequalwritelate`、`scopequalarraylate`、`scopequalincrlate`、`scopequaldncllate`、`scopequallocalleak`、`scopequalwriteearly`、`scopequalcrossfn`、`scopequalmodread`、`scopequalsamestmt`、`native-scopequal-same-stmt`、`native-scopequalreadlate`、`native-scopequalreadearly`、`native-scopequalwritelate`、`native-scopequalarraylate`、`native-scopequalincrlate`、`native-scopequaldncllate`（`compare_interpreter_oracle.mjs` / `compare_native_oracle.mjs`）、`semantic-diagnostic-property-root-later`（`compare_semantic_diagnostics_oracle.mjs`）、`取り込んだモジュールの同名シンボルは展開順の先勝ちで解決する`、`推移的に取り込んだモジュールの変数を裸名で解決する`、`取り込み先の代入はエントリの同名変数をmodList解決で上書きする`、`取り込み先の変数宣言はエントリの同名変数を上書きしない`、`取り込み先関数本体内の代入もmodList順でエントリ変数を上書きする`、`関数定義位置より後のエントリ変数は取り込み先関数から見えない`（`src/runtime/interpreter/tests.zig`）
- TODO識別子: なし

## 関数内の特殊変数『引数』

- 公式実測・source根拠: `nako_gen.mts` は関数本体の先頭で `__self.__vars.set('引数', arguments)` を生成します。値はJavaScriptの `arguments` オブジェクトそのもので、宣言した仮引数に加えて、公式の呼出し規約が末尾へ渡す `__self`（実行コンテキスト）も要素に含まれます。実測では1仮引数の関数呼出しで `引数の要素数` は2、`引数[0]` は第1実引数、`引数[1]` は `[object Object]` でした。
- lnakoの現在動作: semantic analyzer が関数スコープへ `引数` をローカル変数として宣言し、HIR lowererが関数先頭で仮引数の並びから配列を作って束縛します。呼出し側は助詞補完済みの実引数を渡すため `引数[i]` は公式と同じ実引数を返し、束縛は呼出しごとのフレームに閉じるため入れ子呼出しでも壊れません。
- 判定: 仕様（実引数の並びと呼出しごとの束縛）／意図的制限（`引数の要素数` は公式より1小さい。公式の末尾要素はJS実装の実行コンテキスト `__self` であり、lnakoには対応する値がないため合成しません。また仮引数より多い実引数は、lnakoの呼出し規約が仮引数の個数で値を受け渡すため `引数` に現れません。公式はJSの `arguments` が余剰実引数も保持します）
- 対象経路: Interpreter / AOT
- 差分テストID: `arguments-array-in-function`、`arguments-array-per-call`、`arguments-array-local-declaration`、`arguments-array-indexed-write-only`、`arguments-array-function-import`（`compare_interpreter_oracle.mjs`）、`native-arguments-array-in-function`、`native-arguments-array-indexed-write-only`、`native-arguments-array-per-call`、`native-arguments-array-anonymous`、`native-arguments-array-local-declaration`（`compare_native_oracle.mjs`）、`関数内の『引数』は実引数の配列になる`、`『引数』は呼出しごとに独立し入れ子呼出しで壊れない`、`『引数』宣言は同名ローカルとして再利用する`、`仮引数名が『引数』でも実引数配列を参照する`、`読み出しの無い『引数』添字代入でも先頭束縛を作る`（`src/runtime/interpreter/tests.zig`）
- TODO識別子: `TODO: arguments-excess-args`

## 添字・プロパティ代入のコンテナ束縛と評価順

- 公式実測・source根拠: 公式コード生成は `A[k]=v` を `get(name)[k0]..[kn-1] = v` の形にします（`convLet`/`convLetArray`）。ルート変数参照は全ての添字式・値の評価より先に1度だけ束縛され、中間レベルは左辺の走査として添字評価と交互に読み出されます。添字式がルート変数自体を再束縛しても代入は束縛済みの古いコンテナへ行われ、値の評価は全添字の評価後になります。`A[i]をN増やす`（`convInc`）も `$nako_o1 = get(name)` を添字評価の前に生成します。中間読出しがnullishで失敗する場合、後続の添字式・値は評価されません。増減の量式は `v0 = obj[..]` の読み出しとundefined初期化の後、`Number(v0) + Number(incValue)` の行で評価され、書き戻しは量の評価後に `o1[i1]..` を再走査して行います。DNCLモードの自動初期化（`convLetArray`）では、中間添字は `instanceof Array` チェック式と初期化時の書き戻し式で2回評価され、最終代入は `code = name` から生成されるため束縛済みの `tmpVar` ではなくルート変数を読み直します。
- lnakoの現在動作: loweringがルート変数を`load_local`/`load_global`で1度だけ束縛し、中間レベルは`array_get`走査として添字評価と織り交ぜてemitし、最終代入は`element_set`（`container[key]=value`）で行います。増減は `is_undefined`/`coalesce_or_zero`/`increment_values` の分解で、要素読み出し→undefined初期化→量式評価→加算→書き戻しの公式順をそのまま表現します。書き戻しも量評価後に束縛済みの根から再走査します。DNCL自動初期化は `is_array` 条件分岐と `init_array_index` で中間添字をチェック式・書き戻し式の2回評価とし、`check_array_init` 時の最終 `element_set` はルート変数を読み直します。Interpreter・AOT共通で、添字式によるルート変数の再束縛・添字と値の評価順・中間nullish失敗時の後続式未評価・量式の評価位置が公式と一致します。
- 判定: 仕様（評価順・束縛・DNCL再評価）／意図的制限（配列の `length` プロパティ代入: 公式はJS配列として拡張・切り詰めを行いますが、lnakoは `ArrayLengthAssignment` エラーとして拒否します）
- 対象経路: Interpreter / AOT
- 差分テストID: `array-set-container-bound-early`、`array-set-index-before-value`、`increment-indexed-container-bound-early`、`increment-amount-after-read`、`increment-indexed-write-retraverses`（`compare_interpreter_oracle.mjs`）、`native-array-set-container-bound-early`、`native-array-set-index-before-value`、`native-increment-indexed-container-bound-early`、`native-increment-amount-after-read`、`native-increment-indexed-write-retraverses`、`native-dncl-v1-final-assign-root-reread`（`compare_native_oracle.mjs`）、`添字代入はルート変数を添字・値の評価より先に束縛する`、`添字代入は添字式を値の評価より先に評価する`、`添字増減はルート変数を添字評価より先に束縛する`、`増減量式は要素読み出し・undefined初期化の後に評価される`、`添字増減の書き戻しは量の評価後に中間コンテナを再走査する`、`DNCL最終代入は初期化チェック後にルート変数を読み直す`（`src/runtime/interpreter/tests.zig`）
- TODO識別子: なし

## 取り込み文位置でのモジュール実行順序

- 公式実測・source根拠: `replaceRequireStatements` は取り込み文トークンを取り込み先のトークン列で置き換えて単一パースするため、取り込み先のトップレベル文は取り込み文の位置で実行されます。取り込み文は逆順に処理され、filePath単位のinclude guardで最初に処理された辺だけへ内容が展開されるため、同一ファイルの複数取り込みでは最後の取り込み文位置へ内容が載ります。展開は静的なため、ループ内・関数本体内の取り込み文は制御が到達するたびに内容が実行されます。循環時は「展開中」のファイルへの再展開のみが抑止され、エントリ自身はガードへ入らないため循環取り込みで一度だけ再展開されます（自己取り込みも同様に一度だけ再展開されます）。
- lnakoの現在動作: module graphの実効辺（include guard相当）をsemantic bindingで取り込み先モジュールエントリへの `.call` として束縛し、HIRで取り込み文ノードをその呼び出しへ置き換えます。実効辺の決定と同時に静的展開順序（`expand_order`）を採番し、取り込み呼び出しノードにはサイト側・呼び出し先モジュールの順序を `site_module`/`site_order`/`callee_module`/`callee_order` として付与します。実行時は `callee_order <= site_order` の呼び出しのみ「静的展開コピー内で除去される取り込み」に対応するため、サイトモジュールが実行中（interpreterは `active_module_entries` のモジュールindex参照カウント、AOTは `lnako_aot_module_entry_begin`/`end` による分岐）であれば抑止し、それ以外の取り込み呼び出しは制御が到達するたびに実行します。これにより関数本体内・ループ本体内の取り込みや、モジュールをまたぐ関数の相互再帰も公式通り毎回実行されます。スキップ時は現在の『それ』を結果にして呼び出し側の結果書き戻しを無害化します。起動時はルートのエントリのみを実行します。
- 判定: 仕様
- 対象経路: Interpreter / AOT
- 差分テストID: `取り込み文の位置で取り込み先のトップレベルを実行する`、`取り込みはネストしても取り込み文位置の実行順を保つ`、`同一モジュールの重複取り込みは最後の取り込み文位置で一度だけ実行する`、`循環取り込みはエントリ内容を一度だけ再展開する`、`関数本体内の取り込みは呼び出し毎に実行する`、`関数本体内の取り込みは入れ子の取り込みも呼び出し毎に実行する`、`関数本体内の取り込み先変数は呼び出し元のローカルになる`、`関数本体内の取り込み先の関数はグローバルに登録される`、`ループ本体内の取り込みは繰り返し毎に実行する`、`エントリの自己取り込みは一度だけ再展開する`（`src/runtime/interpreter/tests.zig`）
- 関数本体内取り込みの変数スコープ（#74・解消済み）: 公式は取り込み先トークンを取り込み文位置へ展開するため、関数本体内では取り込み先の変数宣言・文が呼び出し元関数のローカルになり、取り込み先の関数定義はグローバルに登録されます。lnakoは関数内の実効取り込み文へ取り込み先トップレベル文のAST複製（`Node.expansion`）を接続し、意味解析で複製内の変数宣言を呼び出し元スコープへ宣言しつつ対象モジュールのモジュール変数を同スコープから隠蔽し、HIRでは複製を `.block` としてloweringします（モジュールエントリ呼び出しは発行しません）。複製内の取り込み文も再帰的に展開し、展開系内で既出のモジュールへの辺は公式のinclude guard相当として展開を抑止します。
- TODO識別子: なし

### 循環取り込み再展開の構文モード

- 公式実測・source根拠: 循環取り込みで再展開されるエントリのコピーは、その循環取り込み文の位置で有効だった構文モードを初期モードとして展開されます（コピー内の取り込み文はinclude guardで除去されるためtailモードも載りません）。エントリ本体とは異なるモードのコピーが実行され得ます。コピー内のトップレベル関数定義はコード生成順の後勝ちで同名関数を上書きします（コピーのモードで生成された本体が全呼び出しに効きます）。
- lnakoの現在動作: 循環実効辺について、コピーの解析開始モード（取り込み文位置のモード＋対象の強制モード）が本体側と異なる場合、またはコピー内で除去される辺が本体側の解析へtailモードを残していた場合は、対象モジュールを文脈のモードで別パースした**文脈変体**（`LoadedModule.variants`）を生成します。変体はモジュール単位で別エントリ関数（`mod__$entry$v{n}`）としてloweringされ、取り込み呼び出しは `callee_variant` で変体を指します（Interpreterは `variant_entries` から解決、AOTは変体エントリ関数へ直接call）。コピー内で残る入れ子の実効辺にも同じ規則を再帰適用します。変体内の関数定義は同名で登録され、名前解決は後勝ちのため全呼び出しが変体本体を使います（公式の静的last-wins相当）。共有本体がコピーと同じ解析になる場合は変体を作りません。
- 判定: 仕様
- 対象経路: Interpreter / AOT
- 差分テストID: `循環取り込みの再展開は文脈のモードで別パースした変体を生成する`（`src/semantic/module_graph.zig`）、`循環取り込みの再展開コピーは取り込み位置のモードで解析される`、`循環取り込みで除去された辺のtailモードはコピーへ適用されない`（`src/runtime/interpreter/tests.zig`）
- TODO識別子: なし
