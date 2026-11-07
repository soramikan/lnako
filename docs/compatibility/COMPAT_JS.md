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
zig build run -- build program.nako3 --compat-js -o program
```

`build --compat-js` の既定はLLVM AOT＋QuickJS runtimeです。通常AOTの
`liblnako_runtime.a` とは別の `liblnako_runtime_compat.a` をリンクし、生成物へ
ESM manifest（source/identity）を収録します。従来の同梱実行ファイル方式は
`--backend embedded` で選びます。

```sh
lnako build program.nako3 --compat-js --backend embedded -o program
```

compat runtime libraryの探索先は通常runtimeと同じく実行ファイル隣接の
`../lib/` です。明示する場合は `LNAKO_AOT_RUNTIME_LIBRARY_COMPAT` を使います。

通常AOT成果物にQuickJS/compat ABIが混入しないこと、compat AOT成果物が
QuickJSとESM情報を収録しESM呼出しに成功することは、生成物のシンボルと実行結果で
検査します。

```sh
node tools/check_aot_quickjs_separation.mjs --compiler zig-out/bin/lnako
```

現時点のAOT compat dispatchは `JS実行` の最小経路だけです。値・Promise・
callback・GCの完全接続と `JS関数実行` / `JSメソッド実行` / `JSオブジェクト取得`
のAOT対応はfollow-up（Issue #55）です。AOTの `JS実行` は専用ABIを直接呼ぶため、
`LNAKO_DISPATCH_TRACE` のdispatch traceにはまだ記録されません（follow-up）。

### 配布アーカイブでの制限

配布アーカイブは現時点で通常AOT runtime（`liblnako_runtime.a` /
`lnako_runtime.lib`）だけを同梱し、`liblnako_runtime_compat.a` は含みません。
そのため配布版で `build --compat-js` のAOTを使うと
`AOTランタイム静的ライブラリを読み込めません` で止まります。配布版では
`--backend embedded` を使うか、`liblnako_runtime_compat.a` を `lib/` へ
別途配置してください。compat runtimeの同梱はfollow-upです。
`tools/check_aot_quickjs_separation.mjs` は配布レイアウトを再現し、この
制限が明確なエラーになることとembedded経路が動くことを検査します。

Windows x86_64 のcompat AOTリンクは、ZigのMinGW向けにビルドしたQuickJSが
`__mingw_*` / pthread 系シンボルを参照し、配布LLVM（MSVC向けclang/lld-link）の
リンク行では解決できないため未対応です（follow-up）。Windowsでは
`--backend embedded` または `run --compat-js` を使用してください。分離・
dispatchの生成物検査はLinuxとmacOSで実施します。

QuickJS証拠を `native` entryのAOT証拠へ合算しません。native分類、QuickJS case、AOT artifact、3 OS attestationはそれぞれ [`../COMPATIBILITY_EVIDENCE.md`](../COMPATIBILITY_EVIDENCE.md) の別state・別経路です。
