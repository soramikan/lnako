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

## 更新規則

- 説明文と実装が食い違う場合は、固定した公式v3.7.24の実行結果を優先する。
- OS依存挙動は各正式OS上の公式処理系をオラクルにする。
- 互換性を維持するためだけに再現した不自然な挙動は、この文書と回帰fixtureの両方へ残す。
- 公式版を更新するときは各項目を再計測し、挙動が変わった項目を移行記録へ残す。
