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
| 辞書リテラルの数値キー | `{1:2}`はJavaScriptのオブジェクト構文なら有効に見えるが、公式パーサーは数値をキーとして受理せず、辞書の閉じ括弧不足に見える文法エラーを返す | 識別子または引用文字列だけを受理し、数値キーは同じ行の構文診断にする | `公式同様に辞書リテラルの数値キーを拒否する`、`parser-diagnostic-cases` |
| 角括弧の分割代入 | `[A,B]=[1,2]`でも分割代入に見えるが、公式パーサーは宣言なしの形を受理しない。`変数[A,B]=[1,2]`または`定数[A,B]=[1,2]`だけが分割宣言になる | 宣言キーワードを必須にし、裸の角括弧形式は同じ行の構文診断にする | `公式同様に宣言なしの角括弧分割代入を拒否する`、`parser-diagnostic-cases`、`native-array-destructure` |
| プリミティブ値への添字代入 | 公式CLI直接実行はNumber、Boolean、String、BigIntへの`A[0]=値`を変更も例外もなく無視する。一方、公式生成JavaScriptはES moduleのstrict modeで動くため、最初のNumber代入から`Cannot create property '0' on number '1'`例外になる。`null`と`undefined`への代入は両経路で`Cannot set properties of null/undefined (setting 'キー')`になる | 通常の利用経路である公式CLI直接実行に合わせ、数値・真偽値・文字列・BigIntへの代入を無操作にする。差分ケースは`oracle: official-source`を明示する。`null` / `undefined`ではキーを文字列化した公式文言を保留例外にし、AOTでも最内側の監視へ渡す | `native-primitive-index-assignment-and-empty-iteration`、`native-nullish-index-assignment-exception`、`プリミティブへの添字代入を無視し非反復値を空として扱う` |
| 反復不能値の`反復` | `null`、`undefined`、Boolean、BigInt、関数は例外にせず要素数0として扱い、反復本体を実行しない | 全ての値を反復入力として受理し、配列・辞書・文字列・Number以外は空反復子へ変換する | `native-primitive-index-assignment-and-empty-iteration`、`プリミティブへの添字代入を無視し非反復値を空として扱う` |

根拠は固定オラクルの
[`core/src/plugin_system_array.mts`](https://github.com/kujirahand/nadesiko3/blob/3.7.24/core/src/plugin_system_array.mts) と
[`core/src/plugin_system_dict.mts`](https://github.com/kujirahand/nadesiko3/blob/3.7.24/core/src/plugin_system_dict.mts) です。

## 文字列

| 構文 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| 補助平面文字の添字と`反復` | 文字列をUnicode文字数ではなくUTF-16コード単位で扱う。`「A😀B」`の添字と反復キーは0〜3になり、1と2の値は高位・低位サロゲート単独になる。CLIが各単独値をUTF-8へ出力するとそれぞれ`�`へ置換される | AOTを含む全経路でUTF-16ヒープ文字列を使い、添字・反復・孤立サロゲートの出力置換を同じ境界にする | `UTF-16文字列の添字と反復をコード単位で処理する`、`native-utf16-string-index-and-foreach` |
| 文字列中のNUL | `U+0000`は文字列の終端ではなく通常のUTF-16コード単位であり、後続文字も保持・出力する | CのNUL終端文字列として埋め込まず、長さ付き`i16`定数からヒープ値を生成する | `UTF-16文字列定数と添字と反復をAOTランタイムへ変換する`、`native-utf16-string-index-and-foreach` |
| 展開あり文字列の中括弧 | `「...」`、`"..."`などの`{...}`は単な文字置換ではなく、内側を通常のなでしこ式として再度字句解析する。全角`｛...｝`も同じ。開き括弧の後ろで最初の`}`/｝を閉じとし、余分な閉じ括弧は文字のまま残るが、閉じのない開き括弧はエラーになる。`『...』`と`'...'`は展開しない | 構文変換で埋め込み式を再度トークン化し、括弧付きの`&`連結へ展開する。その後は通常の意味解析・SSA・AOT値文字列化を共用する | `展開あり文字列の埋め込み式を文字列連結へ変換する`、`native-string-template` |

根拠は固定オラクルの[`NakoLexer.splitStringEx`](https://github.com/kujirahand/nadesiko3/blob/3.7.24/core/src/nako_lexer.mts)と、
そこで作られた`code`トークンを再度字句解析する[`NakoTokenizer.lex`](https://github.com/kujirahand/nadesiko3/blob/3.7.24/core/src/nako_tokenizer.mts)です。

## 比較・単項演算

| 構文 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| 配列・辞書の`==`と`===` | 両辺が配列・辞書なら内容比較や文字列変換をせず、参照が同一かを判定する。同じ内容の別配列`A=[1]; C=[1]`では`A==C`も`A===C`も偽だが、`B=A`なら両方とも真。一方、片辺だけがオブジェクトの`[1]==1`では配列を文字列`「1」`へ変換するため真になる | インタプリタとAOTで、両辺がオブジェクトなら参照同一性を先に判定し、片辺だけならJavaScriptのToPrimitive相当を適用する | `配列の伸長と挿入順辞書の更新を扱う`、`AOT動的比較は文字列変換と参照同一性を区別する`、`native-dynamic-comparison` |
| `+`と他の数値演算の変換差 | `+`だけは非数値オペランドを公式の`__parseFloatOrBigint`で`parseFloat`してから加算する。そのため`"5x"+2`は`7`だが`"5x"-2`は`NaN`、`[]+1`は`NaN`だが`[]-1`は`-1`になる。文字列結合は`+`ではなく`&`が担う | 動的AOT加算はECMAScript `parseFloat`相当、その他の演算はToNumber相当を別経路で実行し、インタプリタと一致させる | `なでしこ式の加算は文字列を連結せず数値へ変換する`、`AOT動的数値演算は文字列・配列・辞書を公式規則で変換する`、`native-dynamic-arithmetic` |
| `÷÷`の負数丸め | 「0方向へ切り捨て」ではなく、公式生成JavaScriptの`Math.floor(left / right)`どおり負の無限大方向へ丸める。`(-5)÷÷2`は`-3` | インタプリタ、動的AOT、数値型が証明済みのLLVM最適化経路の全てでfloorに統一する | `native-dynamic-arithmetic` |
| `かつ` / `&&`と`または` / `||` | 真偽値へ正規化せず、`and`は偽の左辺または右辺、`or`は真の左辺または右辺の値そのものを返す。結果が左辺で決まる場合、表示や関数呼び出しを含む右辺は実行しない | HIRの両辺を先に評価せず、SSA IRで右辺専用ブロックとPHIを生成して値と副作用を両方一致させる | `論理演算の右辺を短絡分岐とPHIへ変換する`、`native-logical-short-circuit` |
| 単項`+` | JavaScriptでは数値変換演算子だが、なでしこ3の`+`は二項演算子だけであり、`+1`、`+A`、`+「1」`はいずれも`+`付近の文法エラーになる | 値変換へ下げず、`+`のソース位置を持つ構文診断として拒否する | `公式同様に単項プラスを拒否する`、`parser-diagnostic-cases` |

固定した公式処理系は[`nako_gen.mts`](https://github.com/kujirahand/nadesiko3/blob/3.7.24/core/src/nako_gen.mts)で
比較をJavaScript演算子へ生成します。上表は公式CLIと生成済みJavaScriptの両方をオラクルにして固定します。

## 標準出力

| 命令 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| `継続表示` | 直ちには出力せず内部プールへ文字列を追加し、次の`表示`がプールと引数をまとめて1行出力する | 同じ | `plugin-system-stdio` |
| `連続無改行表示` | 可変個引数を結合して`継続表示`へ渡すため、次の`表示`まで出力を保留する | 同じ | `plugin-system-stdio` |
| `言` | 命令本体は文字列だけをロガーへ送るが、公式CLIのstdoutロガーを通すと1行出力になり改行が付く。`表示ログ`には追加しない | CLIで同じ1行出力にする | `plugin-system-stdio` |
| `表示` | 保留中の継続表示を先頭に付けて出力し、改行付きの内容を`表示ログ`へ追記する | 同じ | `plugin-system-stdio` |
| 式中の`表示(...)`の戻り値 | 引数を出力するが、その引数値は返さず`undefined`を返す。`1かつ表示("右")`は右辺の表示後、式全体の値が`undefined`になるが、システム変数`それ`は更新しない。命令定義の`return_none: true`により、戻り値あり命令と生成コードが分かれるためである | AOTの表示ヘルパーも出力後に`undefined`を返す一方、`return_none`相当の命令は`それ`へ書き戻さない | `native-logical-short-circuit`、`関数の戻り値だけをシステム変数それへ書き戻す`、`native-function-result-variable` |
| 配列・辞書の`表示` | 配列は要素をカンマで連結し、辞書は内容ではなく`[object Object]`と表示する。自己循環した配列は循環箇所を空文字にするため、自分自身だけを持つ配列の表示結果は空行になる | AOTでも循環検出付きのUTF-16文字列化を通してから出力する | `AOTの値をUTF-16文字列として連結する`、`native-array-and-dictionary` |

根拠は固定オラクルの
[`core/src/plugin_system_stdio.mts`](https://github.com/kujirahand/nadesiko3/blob/3.7.24/core/src/plugin_system_stdio.mts) です。

## 関数呼び出し

| 構文 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| 静的に解決するユーザー関数の引数個数差 | JavaScriptの通常の関数呼び出しと異なり、不足引数を`undefined`で補ったり余分な引数を無視したりしない。定義と呼び出しの個数が違うと、公式コンパイラが実行前に文法エラーとして拒否する | 関数シンボルの形式引数数を意味解析で保持し、直接呼び出しの実引数数が異なる場合は`invalid_argument_count`診断でIR生成前に拒否する | `静的に解決したユーザー関数の引数個数差を拒否する`、`semantic-diagnostic-function-arity-missing`、`semantic-diagnostic-function-arity-extra` |
| 動的なユーザー関数の引数個数差 | 関数値の動的呼び出しでは静的呼び出しと逆に、不足・超過を拒否しない。実引数列の末尾へ内部`sys`オブジェクトを追加してから通常のJavaScript引数規則を適用するため、2引数関数の`F()`は第1引数が`sys`、第2引数が`undefined`、`F(1)`は第2引数が`sys`になる。超過分は無視する。同じ`sys`を呼び出し間で共有する | ネイティブ側では内部プロパティを公開しない共有辞書値を`sys`の不透明な代替値とし、表示の`[object Object]`、参照同一性、不足位置への追加、残りの`undefined`、超過引数無視を再現する | `native-dynamic-function-arity`、`AOT動的関数の不足引数へ共有システム文脈を追加し超過引数を無視する` |
| ユーザー関数の呼び出し結果と`それ` | ユーザー関数の戻り値をシステム変数`それ`へ毎回書き戻す。空関数など結果指定がない関数は以前の`それ`を引き継がず`undefined`を返すが、例外終了した関数は`それ`を更新せず呼び出し前の値を残す。末尾の`それは式`は`それ`代入と関数結果の両方になる。組み込み`表示`のように、戻り値を持っていても`それ`を更新しない命令とは別規則 | AOTで`それ`を常設のGCルート付きグローバルとし、ユーザー関数呼び出し後だけ戻り値を書き戻す。終端が`それ`代入ならそのSSA値、それ以外の正常な戻り値なし終端なら`undefined`を返し、保留例外があれば旧値を選ぶ | `関数戻り値をシステム変数それへ書き戻す`、`native-function-result-variable`、`native-bigint-runtime-exception-monitor` |
| クロージャのローカル変数捕捉 | 無名関数作成時の値をコピーするのではなく、外側の可変な束縛を共有する。作成後に外側が更新した値が見え、クロージャ自身の更新も次回呼び出しまで保持される。内側のクロージャだけが参照する変数も、中間のクロージャが束縛を中継する | インタプリタとAOTの両方で、GC管理の可変セルを外側フレームと各クロージャが共有する。関数値は捕捉セルをGCで追跡し、LLVMの統一コールバックABIは関数コンテキストから同じセルを復元する | `クロージャが外側の可変束縛を共有する`、`closure-shared-mutable-binding`、`AOTクロージャがGC管理の可変セルを共有する`、`native-closure-shared-mutable-binding`、`native-closure-transitive-capture` |

## 例外監視

| 構文 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| `エラー監視`内の`エラー発生` | `エラー発生`より後にある監視本体は実行せず、最も内側の`エラーならば`へ移って`エラーメッセージ`に投げた値を設定する。呼び出し先で投げた値も呼び出し元の監視へ伝播し、ハンドラ終了後は監視構文の後から実行を続ける | インタプリタとAOTで同じ。AOTランタイムは保留例外をGCルートとして保持し、SSAの呼び出し後分岐で関数フレームを越えて最内側ハンドラへ渡す。配列代入や反復初期化など、二項演算以外の命令が生じる実行時エラーを同じ機構へ渡す処理は未実装 | `native-exception-monitor`、`native-nested-exception-monitor`、`native-cross-function-exception`、`保留例外をGCルートとして保持し一度だけ取り出す` |
| BigInt二項演算の実行時エラー | 監視内ならJavaScriptの例外文を`エラーメッセージ`へ格納する。型混在は`Cannot mix BigInt and other types, use explicit conversions`、`÷÷`は`Cannot convert a BigInt value to a number`、符号なし右シフトは`BigInts have no unsigned right shift, use >> instead`となる | JSランタイムを使わない通常モードでも同じ固定文言へ変換する。二項演算直後のSSA例外分岐と保留例外により、呼び出し先で生じた失敗も呼び出し元の監視へ伝播する | `native-bigint-runtime-exception-monitor`、`BigInt実行時エラーを公式JavaScriptの文言へ変換する`、`AOT算術失敗を公式文言の保留例外へ変換する` |
| 監視外の`エラー発生` | 公式`cnako3 source.nako3`はエラー文を標準出力へ出して終了コード0になる一方、公式生成JavaScript＋Nodeは未捕捉例外で終了コード1になる | `lnako run`とAOTは公式生成JavaScript側に合わせて終了コード1にする。差分ハーネスでは`oracle: official-generated`を明示し、公式CLIとの差を隠さない | `native-uncaught-exception`、`監視外のthrowを保留例外としてmainまで伝播する` |

## BigInt

| 構文 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| BigIntリテラルの`表示` | ソースでは末尾に`n`を付けるが、表示時は10進へ正規化して`n`を出力しない。16進・2進・8進や桁区切りも10進表示になる | 任意精度値のまま保持し、同じ10進文字列を出力する | `AOT BigIntを任意精度で生成して真偽判定する`、`native-bigint-literals-and-truthiness` |
| `0n`の条件判定 | 通常のオブジェクト値と異なり`0n`だけが偽、他のBigIntは真になる | AOTでもポインタ先の任意精度値を検査し、同じ真偽値にする | `BigInt定数と真偽判定をAOTランタイムへ変換する`、`native-bigint-literals-and-truthiness` |
| BigIntの除算・剰余 | `/`は0方向へ整数化し、`%`の余りは被除数と同じ符号になる。例えば`-5n/2n`は`-2`、`-5n%2n`は`-1` | 浮動小数点数へ変換せず、任意精度整数の0方向除算を行う | `AOT BigInt算術とNumber混在エラーを処理する`、`native-bigint-arithmetic-and-comparison` |
| BigIntの`÷÷` | 固定した公式v3.7.24でも経路により異なる。`cnako3 source.nako3`はエラー文を標準出力へ出して終了コード0、公式生成JavaScript＋Nodeは`Cannot convert a BigInt value to a number`例外で終了コード1になる | 値を誤生成せず、公式生成JavaScriptと同じ実行時エラーとして拒否する。公式2経路が一致しないため成功差分テストから分離する | `AOT BigInt算術とNumber混在エラーを処理する` |
| 負のBigInt | `-5n`は負のBigIntリテラルとして動作する。一方、変数`A`に対する`-A`は内部的にNumberの`-1`との乗算になり、BigIntとの型混在エラーになる | リテラルだけ符号を値へ取り込み、変数への単項マイナスは公式と同じ乗算形式を保持して型混在を拒否する | `負のBigIntリテラルと変数への単項マイナスを区別する`、`AOT BigInt算術とNumber混在エラーを処理する` |
| BigIntとNumberの比較 | 算術演算では型混在エラーだが、`>`などの関係比較と`==`は許可される。`1n==1`は真、`1n===1`は偽 | 比較時だけNumberを精度損失なく整数と照合し、厳格比較では型を区別する | `AOT BigInt比較をNumberとの間でも精度を落とさず処理する`、`native-bigint-arithmetic-and-comparison` |
| `^`と`**` | `^`はXORではなく冪乗である。またJavaScriptの`**`と異なり、両方とも左結合なので`2^3^2`と`2**3**2`は`64`になる | `^`を`**`へ正規化したうえで、両構文を左結合としてNumberとBigIntの冪乗へ下げる | `冪乗演算子を公式同様に左結合として構文解析する`、`native-number-and-bigint-shifts` |
| 負のBigIntシフト量 | `S=-2n`のとき`8n<<S`は右へ2ビット移動した`2`、`8n>>S`は左へ2ビット移動した`32`になる | シフト量の符号で方向を反転し、任意精度のまま処理する | `AOTのNumberとBigIntシフトを公式規則で処理する`、`native-number-and-bigint-shifts` |
| BigIntの`>>>` | 符号なし右シフトはBigIntに定義されず、実行時エラーになる | 値を生成せず`UnsignedShiftOfBigInt`として拒否する | `AOTのNumberとBigIntシフトを公式規則で処理する` |
| `+`と`&`の文字列 | なでしこ式の`+`はJavaScriptの`+`と異なり文字列連結を行わない。`3+「個」`は`NaN`、`1n+「個」`はBigInt型混在エラーになる。連結は`&`を使い、`1n&「個」`は`1個`、`[1,2]&「個」`は`1,2個`、辞書なら`[object Object]個`になる。自己循環した配列は循環箇所を空文字として扱う | インタプリタとAOTの`+`を数値加算に限定し、`&`は循環を検出しながら値をUTF-16文字列へ変換して連結する | `なでしこ式の加算は文字列を連結せず数値へ変換する`、`AOTの値をUTF-16文字列として連結する`、`native-string-concatenation-and-bigint-string-comparison` |
| BigIntと文字列の比較 | 算術では型混在エラーだが、抽象等価・関係比較では整数として解釈可能な文字列をBigIntへ変換する。`1n==「1」`は真、`1n===「1」`は偽 | UTF-16文字列を整数として厳密に解析し、変換不能時は比較を偽にする | `AOT BigInt比較をNumberとの間でも精度を落とさず処理する`、`native-string-concatenation-and-bigint-string-comparison` |
| NaNとInfinityの表示 | Cの`printf`では環境により`nan`や`inf`になるが、公式は`NaN`、`Infinity`、`-Infinity`と大文字小文字を固定して表示する | 特殊値をLLVM上で先に判定し、固定文字列を出力する | `native-string-concatenation-and-bigint-string-comparison` |
| `増`・`減`の型変換 | 通常の`+`と異なり、未定義の対象は0から開始し、文字列やBigIntもNumberへ変換する。`A=5n; Aを2増`の結果はBigIntではなくNumberの`7`になる | 専用の増減経路で対象と増減量をNumberへ変換し、常にNumberを書き戻す | `増減文は未定義・文字列・BigIntをNumberへ変換する`、`AOT増減は未定義・文字列・BigIntをNumberへ変換する`、`native-increment-and-decrement` |
| 分割宣言の非配列値 | `変数[A,B]=C`でCが非配列でもエラーにせず、C全体を先頭1要素として扱う。Cが`「AB」`なら`A=「AB」, B=undefined`であり、文字単位には分割しない | 配列なら各要素を取得し、非配列なら先頭へ値全体、それ以降へ`undefined`を格納する専用取得処理を使う | `AOT分割宣言は非配列を1要素の値として扱う`、`native-array-destructure` |

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

## AOTランタイムとビルド検証

| 境界 | 分かりにくい挙動 | lnakoの扱い | テストID |
|---|---|---|---|
| AOTの`-O0`〜`-O3`とランタイム静的ライブラリ | CLIの最適化指定はNako SSA IRと生成LLVMモジュールに対する指定であり、別にリンクするZigランタイムまで同じモードにするとDebug版だけがZigの診断用OS依存を持つ | 生成コードは指定レベルを維持し、配布ランタイムはReleaseSafe・strip・compiler-rt同梱で固定する。WindowsではZigの安全検査経路が使うNT APIを`ntdll.lib`で解決する | `Differential native AOT test`、GitHub Actions `Windows x86_64` |
| 16バイト動的値のWindows ABI | `%lnako.Value`をC関数の引数・戻り値として値渡しすると、Windows x64とSystem Vで集約値の呼出規約が異なる。macOS/Linuxで動いてもWindows生成物だけが配列生成時にアクセス違反になり得る | Zig製AOTランタイムとの公開境界では動的値をすべてポインタ渡しにし、集約値のC ABI分類へ依存しない | `公開AOT ABIは動的値をポインタで受け渡す`、`Differential native AOT test`、GitHub Actions `Windows x86_64` |
| binary64の表示桁数 | Cの`printf("%.17g")`は値の往復に十分でも、`PI`を`3.1415926535897931`と表示し、JavaScriptの最短表記`3.141592653589793`と一致しない | インタープリタとAOTで同じ最短表記変換を共有し、`NaN`・無限大・指数表記境界・負のゼロもJavaScript規則へ合わせる | `binary64をJavaScript互換の最短文字列へ変換する`、`native-scalar-system-constants` |
| `check_compat_report.mjs`をQuickJSビルド後に実行 | 検査スクリプト自身が通常版を再ビルドすると、直前に生成したQuickJS対応`lnako`を同じ`zig-out/bin`上で置き換える | 単独実行は従来どおりビルドしてから検査し、既存配布物を検査するCIでは`--no-build`を指定してバイナリを変更しない | `check_compat_report.mjs --no-build`、GitHub Actions `Smoke test` |

## 礼節・言語カタログ・名前空間

| 命令・境界 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| 初回の`敬具` | 内部値が未定義のまま`100`を加えるため一度`NaN`になり、直後の`礼節レベル取得`がfalsey値として`0`へ戻す | 初期状態を未定義相当で保持し、同じく取得結果を`0`にする | `system-runtime-courtesy` |
| `敬具`の加点 | `拝啓`や取得済みの初期値で内部値が`0`になった後は、`100`を加点する | 同じ | `system-runtime-courtesy` |
| 初期`名前空間` | 公式CLI直接実行では`main`固定でなく入力ファイルのベース名。末尾が`.nako` / `.nako3`のときだけ拡張子を外し、ハイフンや別のピリオドは残す。一方、公式生成JavaScript単体では初期化経路が異なり空文字のままになる | `lnako run`とソースから作るAOTは公式CLI側に合わせ、同じファイル名をIRのモジュール名、関数の修飾名、初期`名前空間`に使う。AOT差分ケースは`oracle: official-source`を明示する | `system-runtime-catalog-and-namespace`、`公式と同じファイル名をモジュール名に保つ`、`native-string-system-constants` |
| `名前空間ポップ` | `名前空間設定`時点の`名前空間`だけでなく`プラグイン名`も対で保存し、後から変更された両方を復元する | GCルートとして保持するスタックへ2値を保存して復元する | `system-runtime-catalog-and-namespace` |
| `システム関数一覧取得` | 名前に反して関数だけでなく定数も含む。標準527命令そのものでもなく、既定7プラグインを登録したMapの重複を除いた順序に、カタログ外の別名も含めた478件を返す | 固定カタログから公式のプラグイン登録順・重複上書き・別名を再現した478件を生成する | `system-runtime-catalog-and-namespace` |
| `プラグイン一覧取得` / `モジュール一覧取得` | 追加取り込みのないCLIでは、どちらも既定7プラグインの同じ配列を返す | 同じ配列と登録順を返す | `system-runtime-catalog-and-namespace` |
| `助詞一覧取得` | 最長一致用の内部表ではなく公開用48件を返し、`ものを`などの字句解析用派生形は含めない | 字句解析表と公開表を分離する | `system-runtime-catalog-and-namespace` |
| `AWAIT実行`の引数 | 第2引数が配列でなければ、値を1要素配列へ包んでから関数へ展開する。関数の戻り値がPromiseでなくてもその値を返す | 同じ引数展開を行い、Promiseの場合だけホストイベントループを完了まで進める | `system-runtime-execution-and-debug` |
| `ハテナ関数設定`の配列 | 指定した関数を左から順に適用するが、`ハテナ関数実行`自体は最後の結果を返さず常に`undefined`。`JS:`で始まる要素はJavaScriptを評価する | 戻り値を次の関数へ渡し、命令自体は`undefined`を返す。`JS:`要素だけは通常モードで拒否し、`--compat-js`を要求する | `system-runtime-execution-and-debug`、`compat-js-hatena` |
| `ハテナ関数設定`の文字列 | 非修飾のユーザー関数名を探索せず、システム変数表だけから取得する。ユーザー関数を指定するには関数値を渡す必要がある | 文字列はシステム命令名としてだけ呼び、ユーザー関数は関数値の場合だけ受け付ける | `system-runtime-execution-and-debug`、`system-runtime-hatena-user-name-error` |
| `デバッグ表示` | `__line`の0始まり行番号へ1を加え、入力時のパスを含む`ファイル(行): 値`を表示する。配列・辞書などは先にJSON化する。Windowsではドライブ文字直後のコロンでパスを分割するため、`C:\\...`が`C(行): 値`になる | IRへモジュール名と入力パスを保持し、同じ行番号・JSON化規則・Windowsのドライブ名短縮を再現する | `system-runtime-execution-and-debug` |
| `__DEBUG`の診断ダンプ | デバッグ有効化に加え、Nodeの`console.log`でNakoGlobal内部全体を出す。生成JavaScript全文、循環参照、Mapなどを含み、Nodeの検査表示に依存する | デバッグ状態は有効化するが、製品内部表現の巨大ダンプは標準出力へ出さない。差分テストでは両処理系の言語出力からこの診断だけを分離する | `system-runtime-execution-and-debug` |
| `__DEBUG_BP_WAIT`の非メインプラグイン | ブレイクポイントに一致しても`プラグイン名`が`メイン`でなければPromiseをresolveせず、その後の処理が進まない | 同じく未解決Promiseを返す。差分テストでは非該当の即時復帰と、待機フラグを事前設定した該当経路を検証する | `system-runtime-execution-and-debug` |
| `ASSERT等`の成功時 | Nodeの`assert.strictEqual`を呼ぶため、比較成功時の戻り値は`true`でなく`undefined` | strict-equalで比較し、成功時は`undefined`を返す | `system-runtime-execution-and-debug` |

## BASE64とパス操作

| 命令 | 公式v3.7.24の実際の挙動 | lnakoの扱い | 差分テストID |
|---|---|---|---|
| `BASE64デコード` | Nodeの`Buffer.from(S, "base64")`規則により、空白などの非BASE64文字を無視し、URL-safeの`-` / `_`とpadding省略も受理する。復号バイトが不正UTF-8でも例外にせず`U+FFFD`へ置換する | 同じ寛容な字句規則とWHATWG互換UTF-8置換を使う | `plugin-system-url`、`BASE64のNode互換境界とUTF-8置換を再現する` |
| `拡張子抽出` / `拡張子変更` | 拡張子として認識するのは末尾の`.`とASCII英数字・`_`・`-`・`+`だけ。`.bashrc`全体も拡張子になり、フォルダ区切りは現在のホストプラグインが設定した1種類だけを見る | 同じ文字集合と現在OSの区切り文字を使う | `plugin-system-url` |
| `終端パス除去` / `終端パス削除` | 末尾の区切り文字を全削除せず、1文字だけ除去する。`a//`は`a/`になる | 同じく1文字だけ除去し、2命令を個別登録する | `plugin-system-url` |

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
