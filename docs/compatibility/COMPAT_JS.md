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
zig build -Dcompat-js=true run -- run program.nako3 --compat-js
# 従来方式（既定）
zig build -Dcompat-js=true run -- build program.nako3 --compat-js -o program
# AOT＋QuickJS（opt-in。-Dcompat-js=true でビルドしたlnakoが必要）
zig build -Dcompat-js=true run -- build program.nako3 --compat-js --backend aot -o program
```

`build --compat-js` の既定は従来の同梱実行ファイル方式（embedded）です。
LLVM AOT＋QuickJS runtime は `--backend aot` の明示opt-inで、`-Dcompat-js=true`
でビルドした `lnako` が必要です。AOTは通常AOTの `liblnako_runtime.a` とは別の
`liblnako_runtime_compat.a` をリンクし、生成物へESM manifest（source/identity）を
収録します。

compat runtime libraryの探索先は通常runtimeと同じく実行ファイル隣接の
`../lib/` です。明示する場合は `LNAKO_AOT_RUNTIME_LIBRARY_COMPAT` を使います。

通常AOT成果物にQuickJS/compat ABIが混入しないこと、compat AOT成果物が
QuickJSとESM情報を収録しESM呼出しに成功することは、生成物のシンボルと実行結果で
検査します。

```sh
node tools/check_aot_quickjs_separation.mjs --compiler zig-out/bin/lnako
```

現時点のAOT compat dispatchは `JS実行` と `JS関数実行` の最小経路です。
`JS関数実行` は第1引数の関数名（文字列）をglobal evalで解決し、引数コンテナの
規則は official と同じです（第2オペランドが配列なら要素を実引数へspreadし、
そうでなければ単一実引数）。各実引数は数値・文字列・真偽値・null/undefinedに
加えて、Nako配列→JS配列・辞書→JSオブジェクトの浅いコピーだけを変換します。
要素はプリミティブに限り、ネストした配列/辞書・関数・BigInt・バイト列・
PromiseはQuickJSへ渡す前にAOTとinterpreterで同じ文言の明示的な未対応エラーに
します（officialはそのまま渡すため、この範囲だけ意図的な差分です）。
戻り値も同様に、数値・文字列・真偽値・null/undefinedに加えて、JS配列→Nako配列・
JSオブジェクト→Nako辞書の浅いコピーだけを変換します（要素/値はプリミティブのみ）。
ネストした配列/辞書・関数・BigInt・バイト列
（TypedArray/ArrayBuffer/SharedArrayBuffer/DataView）はAOTとinterpreterで
同じ文言の明示的な未対応エラーにします。戻り値がPromiseのときは、`JS実行` の
AOT経路と同じくdrain後に `lnako_qjs_await` で解決値を待ち、解決値を同じ
プリミティブ／浅い配列・辞書の規則で変換します。rejectはreject理由、pendingは
`QuickJS promise is still pending` を明示エラーにし、無限待機しません
（officialはPromiseをawaitせず `[object Promise]` を返すため、この範囲だけ
意図的な差分です）。`then` が関数のオブジェクト（thenable）もbridgeの
`lnako_qjs_kind` がPromiseとして扱うため、解決できないthenableはpendingと同じ
明示エラーになります。プリミティブ要素の
配列・辞書は `表示` の文字列化が official と同じ（`1,2` / `[object Object]` /
空配列は空行）になることを fixture で固定しています。浅いコピーはJS参照を保持せず、
疎配列の巨大な `length` と辞書のキー数は、AOT/interpreterで同じ1,000,000の
要素数上限を超える場合に明示エラーにします。own enumerable keyを持たない
Map/Set/Date/RegExpなどは空辞書へ変換されます（浅いコピー契約の帰結）。
Symbolなど未分類のJS値は既存の `lnako_qjs_kind` と同じく `undefined` として扱います。
NULを含む辞書キーは既存の `convertObject` / `syncExternal` と同じ制限を継承します。
`JS実行` の戻り値文字列は既存どおりstrict UTF-8で変換するため、孤立サロゲートを
含むJS文字列はinterpreterで変換エラー・AOTで保持という既存差分が残ります
（`JS関数実行` の戻り値だけ本スライスでWTF-8に統一。follow-up）。
interpreterで `JS実行` が
返した配列・辞書は既存のJSオブジェクトを参照渡しし（Nako側の内容を書き戻す）、
浅いコピーになるのはNakoネイティブ値と `JS関数実行` の戻り値だけです。
呼出し時の `this` は official の `apply(null)` と同じ `null` です
（QuickJS bridge が `JS_NULL` を渡すため、strict 関数でのみ観測できます）。
Promise戻り値は解決値をawaitしてから変換しますが、エラー判定前にmicrotaskを
drainするため、呼び出した関数が登録した継続は実行されてから失敗します。
第1引数に
関数値（`JS実行`の結果やcallable proxyなど）を渡す形もAOTでは未対応で、
interpreter/officialとの意図的な差分です（Nako値がJS関数値を保持できるように
なるfollow-up）。
`JSメソッド実行` /
`JSオブジェクト取得`、値・Promise・callback・GCの完全接続はfollow-up（Issue #55）
です。AOTの `JS実行` / `JS関数実行` は専用ABIを直接呼ぶため、`LNAKO_DISPATCH_TRACE`
のdispatch traceにはまだ記録されません（follow-up）。またAOT compat runtimeは
interpreterのhost値bridgeを持たないため、`sys.__getSysVar`等はstrict stubとして
失敗し、`console`などinterpreterがbootstrapするグローバルは存在しません。

### npm bare import と ESM plugin

npm の ESM package は、lock と cache から解決した結果だけを使います。実行時に npm CLI や Node.js を起動しません。

- `build --compat-js`（embedded、既定）は payload format v8 に npm bare import の解決対応表を収録し、起動時の再コンパイルで cache やファイルシステムなしに復元します。lock と cache はビルド時に必要です。
- `--backend aot` は ESM manifest に path・source・所属 namespace・package root・bare alias を収録し、起動時に QuickJS へ module として登録します。bare import は compile 時に解決したモジュール source を生成物へ埋め込むため、実行先に npm・Node.js・cache は不要です。ビルド時に cache が欠けていると解決に失敗します。
- ESM plugin の命令は AOT から呼び出せません。plugin 命令の AOT dispatch は未対応です。plugin モジュール内部の bare import は起動時の bare alias 登録で解決され、`JS実行` の引数内で書いた `import("...")` も同じ alias で解決されます。参照 fixture は `tests/fixtures/package-plugin-npm/`（`aot-main.nako3`）です。
- ESM-only の path 依存（`esm` だけを宣言したパッケージ）を lock で解決するには、`compat-js = true` を宣言した profile を置きます。lock と sync は、`default` が無ければ唯一の profile を自動で選びます。

参照 fixture の流れ:

```sh
LNAKO_NPM_REGISTRY=http://127.0.0.1:<port> lnako lock --package-cache-dir <cache>
lnako sync --offline --package-cache-dir <cache>
lnako run main.nako3 --compat-js
```

### 配布アーカイブ

配布アーカイブは通常AOT runtime（`liblnako_runtime.a` / `lnako_runtime.lib`）と
compat AOT runtime（`liblnako_runtime_compat.a` / `lnako_runtime_compat.lib`）の
両方を `lib/` へ同梱します。展開した配布物でも `--backend aot` が動きます。

Windows x86_64 のcompat AOTリンクは、ZigのMinGW向けにビルドしたQuickJSが
`__mingw_*` / pthread 系シンボルを参照し、配布LLVM（MSVC向けclang/lld-link）の
リンク行では解決できないため未対応です（follow-up）。Windowsでは
`--backend embedded` または `run --compat-js` を使用してください。分離・
dispatchの生成物検査はLinuxとmacOSで実施します。配布物の同梱規則は
[パッケージの作成・公開・配布](../package-system/PUBLISHING.md)も参照してください。

QuickJS証拠を `native` entryのAOT証拠へ合算しません。native分類、QuickJS case、AOT artifact、3 OS attestationはそれぞれ [`../COMPATIBILITY_EVIDENCE.md`](../COMPATIBILITY_EVIDENCE.md) の別state・別経路です。
