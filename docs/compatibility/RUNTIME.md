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
