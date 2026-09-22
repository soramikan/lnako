# Parser・構文のquirks

対象はlexer、正規化、DNCL/DNCL2、インラインインデント、助詞、診断です。公式の変換・parser sourceは固定した [`nako_from_dncl.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/core/src/nako_from_dncl.mts)、[`nako_from_dncl2.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/core/src/nako_from_dncl2.mts)、[`nako_indent_inline.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/core/src/nako_indent_inline.mts) と公式実測を根拠にします。

## 文字列と改行の正規化

- 公式実測・source根拠: ソース前処理はコード部分だけでなく、文字列リテラル内のCRLF/CRもLFへ正規化します。
- lnakoの現在動作: 読み込み時に同じ正規化を行います。実行時のCRLF値を検証するときは `CHR(13)&CHR(10)` で生成し、ソース改行と区別します。
- 判定: 仕様
- 対象経路: Interpreter / AOT / QuickJS
- 差分テストID: `compare_syntax_oracle.mjs`、`compare_parser_oracle.mjs`
- TODO識別子: なし

## 先頭のUTF-8 BOM

- 公式実測・source根拠: 固定v3.7.24の`NakoPrepare.convert`と`NakoLexer`は先頭U+FEFFを正規化・空白処理の対象にせず、`未知の語句`の内部字句エラーで停止します。Nodeの`fs.readFileSync(path, 'utf-8')`はBOMを保持するため、Windowsメモ帳のBOM付きUTF-8は公式cnakoではそのまま実行できません。
- lnakoの現在動作: `source.normalize`がファイル先頭のUTF-8 BOM（`EF BB BF`）だけを本文から読み飛ばし、source mapの先頭をBOM直後の本文先頭へ対応させます。診断の行・列はBOMを除いた本文先頭から数え、先頭行の表示本文からもBOMを除外します。本文中のBOMはそのまま保持します。文字列テンプレートの展開式など元ファイル途中の断片を再字句化する経路はBOM除去を無効化し、断片先頭のU+FEFFも本文として字句エラーにします。
- 判定: 仕様（公式にない入力の寛容化。Windowsメモ帳の既定の「UTF-8」保存をそのまま実行できるようにする）
- 対象経路: Lexer / Parser / Interpreter / AOT
- 差分テストID: なし（公式は先頭BOMで字句エラーになるため`tests/oracle/`の比較対象に含めない）。単体テスト: `先頭のUTF-8 BOMを読み飛ばし本文先頭へ対応させる`、`BOMだけの入力を空の本文として扱う`、`本文中のBOMは読み飛ばさない`、`BOM除去が無効な断片では先頭BOMを本文として保持する`、`先頭のUTF-8 BOMを構文に含めず本文から字句化する`、`先頭のBOM付きでもインデント構文とCRLFを扱う`、`ファイル断片の先頭BOMは本文として字句エラーにする`、`先頭のUTF-8 BOMを本文から構文解析する`、`BOM付きソースの診断位置を本文先頭から数える`、`BOM付きソースの先頭行はBOMを除いて表示する`、`展開式の先頭BOMは本文として拒否する`
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

## 助詞付きの条件式（`AがBならば`）

- 公式実測・source根拠: 公式`yIFCond`は「もし」以降の条件を、演算子比較式とC風呼出しに加えて、助詞`が`の比較形と助詞付きの命令呼出しで受理します。`もし、Aが5ならば`は`eq`ノード（`A`は`が`、`5`は`ならば`の助詞を保持）になり、`もし、Aが3でなければ`は`noteq`になります。二番目の値が条件助詞を持たない場合は位置を戻し、`yCall`が助詞付きの値をスタックへ積んで命令名で呼び出します（`もし、Aが3以下ならば`は`以下(A,3)`、`もし、Dに"a"が辞書キー存在するならば`は`辞書キー存在(D,"a")`）。括弧内も`yValueKakko`経由で同じ`yCall`になるため、`もし、(Aが3以下)ならば`と`もし((A%3)が0と等しい)または(...)ならば`も同じASTになります。「もし」を伴わない`Aが5と等しいならば`は`ySentence`が命令呼出しの直後の`ならば`を見て同じ`yIfThen`へ入ります。`Aが5ならば`（`もし`省略形の等価比較形）は公式も『不完全な文です』で拒否します。`間`条件も`yCall`が助詞付き呼出しをスタックへ積んだまま制御構文へ渡すため、`Aが5以下の間`は`以下(A,5)`を条件とする`間`になります。後判定の`ここまで,(Aが3以下)の間`も同じです。公式の字句解析は「でなければ」「しなければ」「なければ」をすべて否定の条件助詞`でなければ`へ正規化するため、`存在しなければ`のような呼出しも`not`で包まれます。
- lnakoの現在動作: `parseIfCondition`が同じ順序で条件を解決します。lnakoの字句解析は「ならば」「でなければ」を直前の語の助詞にするため、独立トークンを期待する公式の分岐を助詞で判定し、呼出しの命令名に付いた条件助詞は結果の`josi`から落として公式のASTに合わせます。`parseJosiCallExpression`が`yCall`相当のスタック解決を行い、括弧式の解析からも共有します。助詞付きの呼出しの直後が`間`・`回`・`繰返`・`反復`の場合は、呼出しを引数として保持したまま文の解析を続け、制御構文の条件として渡します。`if`ノードの助詞は公式同様に常に空です。
- 判定: 仕様（「もし」省略形へ昇格するのは、公式`yCall`が命令呼出しで確定した場合に相当する、公式の`func token`に相当する既知の命令名・ユーザー定義関数の呼出しかC風呼出しだけ。範囲演算子`1…5`は`function_call`でも命令呼出しではなく、未定義語の助詞付き呼出し（`1を未定義Fならば`）も公式同様に拒否するため昇格しません。C風呼出しは公式も条件文へ入れてから名前解決で失敗するため、既知名の確認は行いません。単独語の文は変数参照と区別できないため、既知の命令名・ユーザー定義関数のときだけ命令呼出しとみなします。関数名は公式`NakoLexer.preDefineFunc`と同じく解析前のトークン走査で集めるため、後方定義の前方参照も解決し、`もし、1をFならば`のように助詞付きの引数でもユーザー定義関数を条件式の命令呼出しへ解決します。無名関数の`関数`キーワードも字句解析では`def_func`になりますが、名前を持たないため本体先頭語（`F=関数(A)それはA`の「それ」）は関数名として集めません。ただし単独語の条件で引数を省略したときの変数「それ」の補完は、他の助詞呼出しと同じく中間表現loweringで確定するため、パーサASTには現れません（`要素数`を単独語で置く従来の形と同じ境界）。ユーザー定義関数を先行値とする連鎖呼出しは従来どおり未対応。先読みは解析対象のトークン列だけを対象にするため、動的に解析される別ソースから外側のユーザー定義関数を助詞付き条件式で呼ぶ形は、名前を解決できないという既知境界を持つ）
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `parser-cases.json`、`interpreter-cases.json`、`fuzz_parser_oracle.mjs`
- TODO識別子: なし

## 条件分岐の「違えば」節

- 公式実測・source根拠: 公式`ySwitch`は『違えば』を読むと、任意の読点を読み飛ばして`yBlock()`で既定節を集め、続けて『違えば』とペアの『ここまで』を消費し、改行を読み飛ばしてから『条件分岐』本体の『ここまで』も消費します。このため`違えば、「@」と表示。ここまで。`のように節を同じ行で閉じる形と、本体の終端を1つだけ書く形（`違えば、「@」と表示。`のあとに『条件分岐』本体の『ここまで』）の両方を受理し、本体の終端を二重に要求しません。『違えば』のない条件分岐は従来どおりです。
- lnakoの現在動作: `parseSwitch`が『違えば』のあとの読点を読み飛ばして既定節を解析し、ペアの『ここまで』と本体の『ここまで』を順に消費します。既定節を解析し終えた時点で本体の終端も消費済みになるため、ループ後の『ここまで』要求は行いません。
- 判定: 仕様（`違えば`を持たない条件分岐の終端要求は従来どおり）
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `parser-cases.json`、`interpreter-cases.json`
- TODO識別子: なし

## 単文の「もし〜ならば」と「違えば」

- 公式実測・source根拠: 公式`yIfThen`は真節が単文（改行で始まらない）のとき`tanbun`を立て、偽節を読んだあとに『ここまで』を要求しません。また真節のあとは`while (this.check('eol')) this.get()`で改行を無条件に読み飛ばしてから『違えば』を調べるため、`もし、A=1ならば、「OK」と表示。`の次行に`違えば、「NG」と表示。`を書けます。偽節が改行で始まる複数行の形も、真節が単文なら『ここまで』は不要です（`違えば\n「NG」と表示\n`）。逆に末尾へ`ここまで`を書くと公式も『『ここまで』の使い方が間違っています』で拒否します。ドキュメント自身が v3.2.27 以前の記法として注記する非推奨形ですが、公式は受理します。
- lnakoの現在動作: `parseIfThen`は真節が単文のとき、直後に『違えば』がある場合だけ改行を読み飛ばして偽節へ繋ぎます。lnakoのASTは改行を保持するため、無条件に読み飛ばすと既存の文区切りが変わるためです。単文の真節では『ここまで』を要求せず、末尾の`ここまで`は公式同様に拒否します。
- 判定: 仕様（`違えば`を持たない単文の`もし`文の終端規則は従来どおり）
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `parser-cases.json`、`interpreter-cases.json`
- TODO識別子: なし

## DNCL/DNCL2モードの検出と強制

- 公式実測・source根拠: `!DNCLモード`、`!DNCL2`、`💡`系ディレクティブはソース先頭のトークンindex 0..100（`i > 100`で打ち切り、先頭101個分）でのみ検出され、複数のモードディレクティブは同時に有効化されます。検出はlexerが行い、語形変換は `convertDNCL2` → `convertDNCL` → インデント構文変換 → インラインインデント変換の順で適用されます。
- lnakoの現在動作: lexerが同じ規則（スキップした公式トークンを含むindexで `<= 100`）で `Mode` 構造体（`dncl` / `dncl2` / `indent`の独立フラグ）へ記録し、syntax transformで同じ順序・同じ行単位アルゴリズムを適用します。公式に存在しない入口として、`.dncl`拡張子はDNCLモード(v1)、`.dncl2`拡張子はDNCL2を強制し、`--dncl` / `--dncl2`フラグはエントリモジュールへ同じモードを強制します。公式同様にv1とv2を同時有効化すると「を実行し、そうでなければ」がv2側の先取り変換で壊れるため、`.dncl`はv1のみを強制します。`--dncl`と`--dncl2`の同時指定は異なる方言の同時強制になるため、build/run/check/testの全コマンドで usage エラー（終了コード2）にします。同様にエントリ拡張子と反対側の方言フラグ（`.dncl`+`--dncl2`、`.dncl2`+`--dncl`）も同時有効化になるため同じ usage エラーへします（`--compat-js`埋め込み実行ファイルの生成時にも同じ検査を行います）。`check`/`test`は`--dncl`/`--dncl2`のみ受理し、それ以外の引数（`--dncll`のようなtypoや余分な位置引数を含む）は usage エラー（終了コード2）で拒否します。`run`は`--`より前で`-`始まりの引数を`--compat-js`/`--dncl`/`--dncl2`に限定し、位置引数は従来通りプログラム引数として許容します。
- 判定: 仕様（拡張子・フラグは公式にないlnako独自の入口）
- 対象経路: Lexer / Parser / Interpreter / AOT
- 差分テストID: `compare_lexer_oracle.mjs`、`compare_syntax_oracle.mjs`、`.dncl/.dncl2拡張子でDNCL系モードを強制する`、`エントリの.nako3へ--dncl/--dncl2相当のモードを強制する`、`エントリ拡張子と反対側のDNCL強制フラグは競合エラーにする`、`モード指定の検出境界は公式の先頭101トークンと一致する`
- TODO識別子: なし

## 文中の「DNCLモード」「DNCL2モード」文

- 公式実測・source根拠: ディレクティブ形式以外に、単独文としての `DNCLモード` / `DNCL2モード` を公式parserは受理し、その文の位置以降だけ対応モードを有効化します（位置依存）。先頭ディレクティブはファイル全体へ作用しますが、文中のモード文はそれより前の行へは遡及しません。
- lnakoの現在動作: lexerが先頭100トークン内のディレクティブに加えて文中のモード文をモードtokenとして出力し、parserがその文を読んだ時点で自身のモード状態を更新します。以降の文だけが新しいモードで解析されます。
- 判定: 仕様
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `dncl-v1-mode-statement-positional`、`dncl2-mode-statement-positional`、`native-dncl-v1-mode-statement-positional`、`native-dncl2-mode-statement-positional`（`compare_interpreter_oracle.mjs`、`compare_native_oracle.mjs`）
- TODO識別子: なし

## DNCL v1の配列添字と要素代入の自動初期化

- 公式実測・source根拠: `!DNCLモード`の配列添字は1始まりで、`A[1]`は内部index 0を参照し、`A[0]`は範囲外としてundefined相当になります。多次元参照は添字の並びが逆転します。`checkInit`により、宣言なしの`A[1]=5`は30要素の0配列を生成し、多次元代入の欠落した中間コンテナも同じ30要素の0配列で初期化されます。DNCL2は0始まりを維持しつつ、同じ自動初期化を持ちます。中間レベルの初期化判定は `if (!(tmp[k0]..[ki] instanceof Array)) { tmp[k0]..[ki] = 新規配列 }` で、check式とwrite-back式で同一添字式を評価し直すため、副作用のある添字式は初期化が走る各レベルで2回評価され、write-backの親がnullishなら `Cannot set properties of …` で失敗します。
- lnakoの現在動作: parserがDNCL v1の添字を`index-1`へ変換し多次元添字を反転します。変換は変数参照だけでなく配列リテラル・括弧式などの非変数レシーバにも適用します。AST→HIR→SSA IRへ`check_array_init`フラグを伝搬し、Interpreter・AOTの両方で未宣言変数・非配列値・欠落中間コンテナへ30要素の0配列を生成します。中間レベルは`array_get`走査+`is_array`判定+条件分岐+`init_array_index` write-backへ分解され、check式とwrite-back式で添字式を公式と同じ回数だけ評価し直します。ルート変数は`ensure_array_var`直後に一度だけ束縛され、最終代入もその束縛済みコンテナへ`element_set`で書き込みます。
- 判定: 仕様
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `dncl-v1-array-*`、`dncl2-array-*`、`native-dncl-v1-array-*`、`native-dncl2-array-*`（`compare_interpreter_oracle.mjs`、`compare_native_oracle.mjs`）
- TODO識別子: なし

## 1つの『[ ]』内の添字数制限

- 公式実測・source根拠: 1つの括弧内のカンマ区切り添字は最大3つまでで、4つ以上は `配列アクセスで指定ミス` の構文エラーになります。`A[i][j][k][l]` のような `@`/`]`連鎖は別扱いで制限されません。読み取り側は構文エラーですが、代入側 `A[1,2,3,4]=1` は公式では構文を通り実行時エラーになります。
- lnakoの現在動作: 読み取り側は3を超える添字を `invalid_array_access` 構文エラーとして拒否し公式と一致します。代入側は公式と同様に構文を通り、`A[1,2,3,4]=1` は `Cannot read properties of undefined (reading '1')` の実行時エラーになります（差分テストなし・実測確認）。
- 判定: 仕様（代入側はエラー分類のみ差異）
- 対象経路: Parser
- 差分テストID: `parser-diagnostic-cases.json`
- TODO識別子: なし

## 配列・プロパティ要素の増減

- 公式実測・source根拠: `A[i]をN増やす` / `A[i]を減らす` は要素参照を対象に取り、要素がundefinedなら0として扱います。未宣言のルート変数や欠落した中間コンテナは自動初期化されず実行時エラーになります。
- lnakoの現在動作: loweringが `is_undefined`/`coalesce_or_zero`/`increment_values`/`element_set` の分解命令列へ展開し、Interpreter・AOTとも同じ規則で処理します。コンテナと添字は1度だけ束縛され（公式の `$nako_o1 = get(name); $nako_i1 = key` 相当）、量式は要素読み出し・undefined初期化の後に評価され、書き戻しは量評価後に束縛済みの根から再走査します。未宣言・undefined/nullなルートまたは中間レベルは `Cannot read properties of undefined/null (reading '<key>')`（公式のTypeError相当）で失敗します。
- 判定: 仕様
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `dncl-v1-increment-indexed`、`dncl2-increment-indexed`、`dncl-v1-increment-indexed-undeclared`、`dncl-v1-increment-indexed-undefined`、`dncl-v1-increment-indexed-null`、`dncl-v1-increment-indexed-mid-undefined`、`dncl-v1-increment-indexed-dict`、`increment-amount-after-read`、`increment-indexed-write-retraverses`、`native-increment-amount-after-read`、`native-increment-indexed-write-retraverses`、`native-dncl-v1-increment-indexed`、`native-dncl2-increment-indexed`、`native-dncl-v1-increment-indexed-undeclared`、`native-dncl-v1-increment-indexed-undefined`、`native-dncl-v1-increment-indexed-null`、`native-dncl-v1-increment-indexed-mid-undefined`、`native-dncl-v1-increment-indexed-dict`、`native-increment-object-to-primitive`
- TODO識別子: なし

## 添字位置の裸の命令語

- 公式実測・source根拠: カンマ直前の添字位置にある関数語（`A[1,表示,2]`、`A[1,f,2]`、代入側の `A[f,0]=9`）は公式のfunc token規則で値として受理されず `配列アクセスで指定ミス` の構文エラーになります。一方、最後の添字位置や式中の裸の命令語（`A[表示]`、`A[1,表示]`）は公式では0引数呼出しとして生成され、命令の副作用が実行されてから戻り値（`表示` 等はundefined）が添字値になります。`X=表示` のような戻り値なし命令の値への代入は公式では文法エラーです。
- lnakoの現在動作: カンマ直前の裸の関数語は読み出し側・代入側の両方で `bare_index_word` として `invalid_array_access`（`配列アクセスで指定ミス`）を発行し公式と一致します。最後の添字位置や式中の裸の命令語は、ユーザー定義関数・組み込み命令とも暗黙呼出しとして実行され公式と一致します（`B=A[表示]` は `表示(それ)` の副作用が実行されます）。`A[表示]` のような文レベルの裸の添字参照は、公式と同じく『不完全な文です。』の文法エラーになります。
- 判定: 仕様（カンマ直前の診断、最後の添字位置・式位置の暗黙呼出し、文レベル裸添字参照の文法エラー化）／既知の差異（`X=表示` のような戻り値なし命令の値への代入の文法エラー化は既存の境界）
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `semantic-diagnostic-bare-index-word`、`semantic-diagnostic-bare-index-word-dncl`、`semantic-diagnostic-bare-index-word-assign`（`compare_semantic_diagnostics_oracle.mjs`）
- TODO識別子: `TODO: builtin-word-value-position`

## 呼出し結果への添字適用

- 公式実測・source根拠: `F(A)[i]` のように括弧呼出しの直後へ続く `[i]` は、公式では呼出し結果への添字ではなく別の式文として解釈されます（`二倍([5,6])[1]を表示` は `[1]` が表示対象になり `1` を出力します）。
- lnakoの現在動作: 呼出し結果への添字として解釈し、undefined相当を返します。通常モード・DNCLモードの両方で同じ差異です。
- 判定: 未実装境界（DNCL固有ではないparser差異）
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: なし
- TODO識別子: `TODO: call-result-index-statement`

## 関数値呼出し（call_value）の連鎖とpostfix

- 公式実測・source根拠: `F(1)(2)`・`G()()()`のように呼出し結果の直後の`(`は関数値呼出し（call_value）として連鎖し、`(`の数だけ多段に評価されます（`G()()()を表示`は各段の戻り値を順に呼んで`6`を出力します）。call_valueの直後の`@`・`[`・`.`はpostfixとして続けず、`F()()@0`・`F()().x`は『不完全な文です。『call_value』が解決していません』、`F()()[0]`は未解決の単語になります。括弧で括ったcall_valueは通常の値として扱われ、`(F()())[0]`・`(F()())@0`・`(F()()).x`は受理されます。括弧で括った呼出しや語の直後の`(`はcall_valueへ結合せず、`(F())()`は`(...)の解析エラー`、`(F)(3)`は未解決の単語になります。
- lnakoの現在動作: 同じ構造で解析します。助詞を持たない`function_call`・`call_value`の直後の`(`はcall_valueとして連鎖し、`(`の数だけ入れ子のcall_valueを作ります。括弧済みノード（`grouped`）の直後の`(`は連鎖せず次の括弧式として読み、call_valueの直後の`@`・`[`・`.`は『不完全な文です。『call_value』が解決していません』で拒否します。`F()()[0]`だけは公式が別の診断（未解決の単語・文末位置）で拒否するため、メッセージは『call_value』未解決としますが拒否一致です。
- 判定: 仕様
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `call-value-multi-chain`、`native-call-value-multi-chain`、`parser-diagnostic-cases.json`（`F()()@0を表示`、`F()().xを表示`、`(F())()を表示`）
- TODO識別子: なし

## 「の」助詞の関数呼出し

- 公式実測・source根拠: `Aの要素数`のように、先行値の助詞`の`が関数宣言の助詞一覧と一致すると関数呼出しになります（`要素数(A)`相当）。一致しない`Aの表示`は未解決単語の文法エラーになります。
- lnakoの現在動作: 既知の命令名（カタログ種別が「関数」の名前）へ解決できる場合、公式`yCallFunc`と同じく助詞スロットへ引数を割り当てる呼出しとして解決します。`「abc」の要素数を表示`は`3`を出力します。判定はパーサが受け取る命令名の一覧（`ParseOptions.builtin_commands`）だけで行うため、同じ名前の変数がスコープにある場合は呼出しとして解決しません（`5回`のあとの`回数を表示`は変数`回数`の値を表示します）。
- 判定: 仕様（命令名一覧に無い名前・ユーザー定義関数を先行値とする連鎖は未対応）
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `parser-cases.json`（`「abc」の要素数を表示`、`「abc」の大文字変換を表示`）、`native-system-chained-builtin-call`
- TODO識別子: なし

## 助詞付き引数の省略

- 公式実測・source根拠: 助詞呼出しで引数を省略すると、公式`yCallFunc`は不足スロットを変数「それ」で補完する（`core/src/nako_parser3.mts:1502-1514`）。補完は助詞スロット単位で、引数は末尾スロットから助詞一致で取り出し、足りないスロットへ`それ`を入れる。2個以上不足し、かつ「引数が1つ以上ある」「命令の助詞が無い」「連文助詞が付く」のいずれかを満たすときだけ文法エラー『関数『X』の引数が不足しています。』になる。C風呼出しは従来どおり個数一致が必要。
- lnakoの現在動作: 組み込み命令・ユーザー定義関数とも同じ補完を実装し、`それは5`に続く`表示。`は5を出力する。`「a」を「X」に置換`のように先頭引数を省略した呼出しも、助詞スロットへ割り当て直して`それ`を補う。助詞がどのスロットにも一致する引数が残る場合は補完せず元の並びを渡す。
- 判定: 仕様
- 対象経路: Parser（補完の計画は中間表現loweringで確定）/ Interpreter / AOT
- 差分テストID: `native-system-particle-implicit-it`、`native-system-particle-implicit-it-function`、`semantic-diagnostic-builtin-insufficient-arguments`、`semantic-diagnostic-function-insufficient-arguments`、`native-system-array-particle-omission`、`semantic-diagnostic-builtin-arity-missing`、`semantic-diagnostic-builtin-arity-extra`
- TODO識別子: なし

## 助詞が宣言と一致しない引数

- 公式実測・source根拠: 助詞呼出しの引数は命令の宣言助詞と照合され、どのスロットにも一致しない値は未解決の単語として文法エラー『未解決の単語があります』になります（`AがBを足す`は`足す`の宣言助詞`に`/`を`と一致しないため文法エラー）。
- lnakoの現在動作: 一致しない助詞の引数も位置引数として渡すため、`AがBを足す`は`3`を出力します。連鎖呼出し（`「abc」で大文字変換を表示`）でも同じで、公式は文法エラー、lnakoは値を返します。一致する助詞（`AにBを足す`、`「abc」の大文字変換`）は公式と一致します。
- 判定: 未実装境界（引数の助詞シグネチャ照合と未解決語診断。連鎖固有ではなく従来からの一般境界）
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: なし
- TODO識別子: `TODO: josi-signature-argument-match`

## 深い入れ子AST

- 公式実測・source根拠: 公式も極端に深い入れ子では文法エラー『Maximum call stack size exceeded』を返し、受理しません。固定オラクルでの実測は、連鎖呼出しが2,000段成功・3,000段失敗、`1+1+...`が2,000項成功・3,000項失敗、`((((1))))`が1,000段成功・2,000段失敗です。
- lnakoの現在動作: 上限を設けて位置付き診断`nesting_too_deep`（『式や命令の入れ子が深すぎます』）へ収束させます。文の入れ子は`max_parse_nesting_depth`（1,024）で数え、パーサ自身が深い括弧・ブロック・同一行の制御構文でプロセススタックを使い切るのを防ぎます（すべての文の解析は`parseStatement`を通るため、ブロックと同一行の`もし`・ループ本体・スコープ指定・無名関数を同じ1カウントで数えます）。式の入れ子は`parseExpressionWithContext`（演算子再帰）と`parseUnary`（単項演算子の自己再帰）で数えます。連鎖呼出しと左入れ子の演算子はパーサの再帰を深くしないまま深いASTを作るため、解析後に明示的なスタックでASTの深さを測り`max_ast_depth`（2,048）で判定します。両上限とも公式が受理する段数（連鎖2,000段・`+`2,000項・括弧1,000段）を含み、公式が失敗する段数（3,000段・2,000段）を下回ります。公式の失敗境界はJSのスタック残量に依存するため、実測していない帯（連鎖2,049〜2,999段など）では公式より厳しくなる可能性があります。関数内取り込みの展開子（`ast.Node.expansion`）はファイル単体の解析時検査より後に接続されるため、接続時に「取り込み元での位置＋取り込み先のAST深さ」を積み上げて上限を判定し（超過する辺は展開しない）、接続後に`children`と`expansion`を合わせた深さも測り直します（超過時は、展開子の位置が別モジュールの複製なので、その展開を導入した取り込み文の位置を診断します）。
- 判定: 仕様（上限超過は位置付き診断。公式の境界は実行環境依存のため段数の完全一致は保証しない）
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: なし（公式の診断本文がJS実行時のメッセージのため、段数と本文の差分テストは対象外）
- TODO識別子: なし

## 助詞付き組み込み命令の連鎖呼出し

- 公式実測・source根拠: 先行する組み込み命令名の助詞が関数宣言の助詞一覧と一致すると、その命令を呼び出して結果を次の命令の引数にする（`大文字変換を表示`は`表示(大文字変換(それ))`相当、`要素数を表示`は`表示(要素数(それ))`相当）。連鎖する命令名に付く助詞は命令自身の引数ではなく、次の命令の引数スロットへ渡す値の助詞なので、命令の宣言助詞と一致していなくても連鎖する（`要素数`の宣言は`の`だけだが、`それは「abc」`に続く`要素数を表示。`は公式で`表示(要素数(それ))`になり`3`を出力する）。逆に助詞の宣言と一致しないのは先行する値の助詞で、公式はそれを未解決の単語として文法エラーにする（`「x」で大文字変換を表示`は`未解決の単語があります: [文字列『x』で]`）。この照合は連鎖固有ではなく「助詞が宣言と一致しない引数」の境界である。
- lnakoの現在動作: パーサが助詞付きの既知命令名を連鎖呼出しとして解決し、公式と同じ入れ子の`func`ノードを作ります（`それは「abc」`に続く`大文字変換を表示。`は`ABC`を出力）。文位置だけでなく、代入・変数宣言・`それは`の右辺（`parseCallExpression`経由）でも同じ入れ子の呼出しにします（`A=「abc」の要素数を文字数`の右辺は文位置の`「abc」の要素数を文字数`と同じ`文字数(要素数("abc"))`）。省略引数の「それ」補完は従来どおり中間表現loweringで行うため、ASTには`それ`を挿入しません。ただしnodeプラグインが同名のグローバル変数を`install`で設定する`デスクトップ`・`マイドキュメント`・`テンポラリフォルダ`の3命令は一覧から除き、助詞付きでも公式の`func`呼出しではなくglobal-readへlowerします（助詞の無い`ファイル名抽出(デスクトップ)`も同じグローバルを読むため、両経路を揃える意図的な境界です。差はASTと計測経路だけで出力は公式と一致します）。
- 判定: 仕様（命令名一覧に無い名前とユーザー定義関数を連鎖の先頭に置く形は未対応、nodeプラグインの同名グローバルを持つ3命令は連鎖対象外。連鎖の判定は命令名の一覧だけで行い、助詞の宣言照合は行わない。公式も同じくfunclistの名前だけで`func token`化する）
- 対象経路: Parser / Interpreter / AOT
- 差分テストID: `parser-cases.json`、`native-system-chained-builtin-call`
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
