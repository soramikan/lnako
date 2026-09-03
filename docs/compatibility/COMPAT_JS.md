# QuickJS互換モードのquirks

QuickJSは通常モードの代替runtimeではありません。`--compat-js` を明示したときだけ、JS固有命令とES module形式のpluginを実行します。

## 対象範囲

`compat/v3.7.24/compat-js-evidence.json` の対象は4 catalog entry、9 case（成功6、期待失敗3）です。操作は `eval`、`lookup`、`call`、`method-call` で、native dispatch evidenceとは別に集計します。

| 命令 | 公式側の挙動 | lnakoの現在動作 | 判定 |
| --- | --- | --- | --- |
| `JS実行` | JS sourceを評価して値を返す | QuickJSへ明示的に渡し、JS値をNako値へ変換 | 仕様 |
| `JSオブジェクト取得` | object propertyを取得 | QuickJS object lookupを実行 | 仕様 |
| `JS関数実行` | JS functionを呼び出す | 引数と戻り値を変換して呼び出す | 仕様 |
| `JSメソッド実行` | receiver付きmethodを呼び出す | receiverを保持して呼び出す | 仕様 |

## 境界

- 公式実測・source根拠: JS値の `undefined`、null、数値、文字列、配列、object、function、Buffer相当は、Nakoの値表現と同一ではありません。失敗caseは公式JSエラーを成功値として扱いません。
- lnakoの現在動作: QuickJS adapterで値を変換し、成功6 caseと期待失敗3 caseを別々に検証します。通常のInterpreter／LLVM AOT routeへQuickJSを暗黙に導入しません。
- 判定: 意図的制限
- 対象経路: QuickJS
- 差分テストID: `compat-js-basic`、`compat-js-host`、`compat-js-find-quirks`、`compat-js-mutation`
- TODO識別子: `TODO: compat-js-failure-diagnostic-equivalence`

## buildと実行

```sh
node tools/setup_quickjs.mjs
zig build -Dcompat-js=true
zig build -Dcompat-js=true test
zig build run -- run program.nako3 --compat-js
```

QuickJS証拠を `native` entryのAOT証拠へ合算しません。native分類、QuickJS case、AOT artifact、3 OS attestationはそれぞれ [`../COMPATIBILITY_EVIDENCE.md`](../COMPATIBILITY_EVIDENCE.md) の別state・別経路です。
