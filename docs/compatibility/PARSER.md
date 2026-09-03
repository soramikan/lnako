# Parser・構文のquirks

対象はlexer、正規化、DNCL/DNCL2、インラインインデント、助詞、診断です。公式の変換・parser sourceは固定した [`nako_from_dncl.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/core/src/nako_from_dncl.mts)、[`nako_from_dncl2.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/core/src/nako_from_dncl2.mts)、[`nako_indent_inline.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/core/src/nako_indent_inline.mts) と公式実測を根拠にします。

## 文字列と改行の正規化

- 公式実測・source根拠: ソース前処理はコード部分だけでなく、文字列リテラル内のCRLF/CRもLFへ正規化します。
- lnakoの現在動作: 読み込み時に同じ正規化を行います。実行時のCRLF値を検証するときは `CHR(13)&CHR(10)` で生成し、ソース改行と区別します。
- 判定: 仕様
- 対象経路: Interpreter / AOT / QuickJS
- 差分テストID: `compare_syntax_oracle.mjs`、`compare_parser_oracle.mjs`
- TODO識別子: なし

## DNCLの「でないならば」

- 公式実測・source根拠: `!DNCLモード`の条件末尾は変換段階で `でなければ` へ正規化され、parserでは条件全体を `not` nodeで包みます。単なる助詞削除ではありません。
- lnakoの現在動作: syntax transformとparserで同じ否定nodeを生成します。
- 判定: 仕様
- 対象経路: Interpreter / AOT / QuickJS
- 差分テストID: `compare_parser_oracle.mjs`、`fuzz_parser_oracle.mjs`
- TODO識別子: なし

## DNCLの「すべての値を〜にする」

- 公式実測・source根拠: `Aのすべての値を0にする`は通常の括弧呼出しではなく、助詞付きの連続引数へ変換されます。末尾の `する` が欠けた縮小入力も、公式変換は同様に受理する場合があります。
- lnakoの現在動作: 公式のtoken列と引数構成を再現します。末尾語が欠けた入力を新しい安定構文として保証せず、公式互換の差分ケースとして扱います。
- 判定: 公式バグ候補（末尾語欠落の寛容さ）
- 対象経路: Interpreter / AOT / QuickJS
- 差分テストID: `compare_syntax_oracle.mjs`、`fuzz_parser_oracle.mjs`
- TODO識別子: `TODO: official-dncl-all-elements-tail`

## DNCL2の同一行「そうでなくもし」

- 公式実測・source根拠: 変換後の `そうでなくもし` は `違えば` と `もし` の2 tokenになります。同じ行に続く内側の `もし` が合成終端を消費するため、外側の明示 `ここまで` を要求しない形があります。
- lnakoの現在動作: 同一行の短文分岐だけこの終端規則を適用し、別行の `違えば` では外側の終端を要求します。
- 判定: 仕様
- 対象経路: Interpreter / AOT / QuickJS
- 差分テストID: `compare_syntax_oracle.mjs`、`fuzz_parser_oracle.mjs`
- TODO識別子: なし

## 助詞付き引数の省略

- 公式実測・source根拠: C風呼出しではarity不足・超過が文法エラーになりますが、助詞構文では不足引数が `undefined` として渡される命令があります。例えば結合の区切り値が未指定でも、命令自体は実行されます。
- lnakoの現在動作: C風呼出しには固定catalogのarity診断を適用し、助詞構文は公式同様に不足値を補います。
- 判定: 仕様
- 対象経路: Interpreter / AOT / QuickJS
- 差分テストID: `native-system-array-particle-omission`、`semantic-diagnostic-builtin-arity-missing`、`semantic-diagnostic-builtin-arity-extra`
- TODO識別子: なし

## 辞書リテラルの数値キー

- 公式実測・source根拠: `{1:2}` はJavaScriptオブジェクトのようには受理されず、辞書の閉じ括弧不足に似た構文診断になります。
- lnakoの現在動作: 識別子または引用文字列をキーとして受理し、数値キーは公式相当の構文診断にします。
- 判定: 仕様
- 対象経路: Parser / Interpreter / AOT / QuickJS
- 差分テストID: `parser-diagnostic-cases.json`
- TODO識別子: なし

## 宣言なしの角括弧分割代入

- 公式実測・source根拠: `[A,B]=[1,2]` は分割代入として受理されず、`変数[A,B]=...` または `定数[A,B]=...` の宣言形だけが分割宣言になります。
- lnakoの現在動作: 宣言キーワードを必須にします。
- 判定: 仕様
- 対象経路: Parser / Interpreter / AOT / QuickJS
- 差分テストID: `parser-diagnostic-cases.json`
- TODO識別子: なし

## 位置付き診断とparser progress

- 公式実測・source根拠: 公式parserは不正入力でも診断を返して終了し、同じcursor位置を繰り返して無期限に待ち続けることを互換仕様にはしません。
- lnakoの現在動作: token消費が進まないparser loopを検出し、ファイル・行・列・診断コードを伴うエラーへ収束させます。生成fuzzではready handshake、caseごとのtimeout、listener/timer cleanupを使います。
- 判定: 意図的制限（安全な終了）
- 対象経路: Parser / Interpreter / AOT / QuickJS
- 差分テストID: `fuzz_parser_oracle.mjs`、`fuzz-regressions.json`
- TODO識別子: なし

## 未実装境界

公式に存在する全ての曖昧な省略や将来構文を推測実装しません。未対応構文は、誤ったASTを生成せず、元位置付きで拒否します。追加の境界はこの文書の書式に従って差分fixtureと一緒に記録します。
