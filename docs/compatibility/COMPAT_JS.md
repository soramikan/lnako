# QuickJS互換モードのquirks

QuickJSは通常モードの代替runtimeではありません。`--compat-js` を明示したときだけ、JS固有命令とES module形式のpluginを実行します。

## 対象範囲

`compat/v3.7.24/compat-js-evidence.json` の対象は4 catalog entry、9 case（成功6、期待失敗3）です。操作は `eval`、`lookup`、`call`、`method-call` で、native dispatch evidenceとは別に集計します。

| 命令 | 公式側の挙動 | lnakoの現在動作 | 判定 |
| --- | --- | --- | --- |
| `JS実行` | JS sourceを評価して値を返す | QuickJSへ明示的に渡し、JS値をNako値へ変換 | 仕様 |
| `JSオブジェクト取得` | グローバル名からJS値を取得（1引数） | interpreterは1引数形を維持し、lnako拡張の2引数 `(OBJ, KEY)` はexternal bindingのプロパティ取得 | 仕様＋拡張 |
| `JS関数実行` | JS functionを呼び出す | 引数と戻り値を変換して呼び出す | 仕様 |
| `JSメソッド実行` | receiver付きmethodを呼び出す | external bindingのreceiverを保持して呼び出す（AOT最小dispatch） | 仕様 |

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

現時点のAOT compat dispatchは `JS実行`・`JS関数実行`・`JSオブジェクト取得`・
`JSメソッド実行` の最小経路です。`JS関数実行` の戻り値である配列・辞書は、浅い
コピー内容に加えてQuickJS参照（external binding）を保持し、後続の
`JSオブジェクト取得` と `JSメソッド実行` が同じJSオブジェクトを参照します。
external bindingはNako側ObjectがGCで回収されるときにQuickJS参照を1回だけ解放します
（通常AOT runtimeはQuickJSを参照しない汎用ハンドル）。
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
空配列は空行）になることを fixture で固定しています。浅いコピー内容は従来どおり
プリミティブだけですが、戻り値の配列・辞書はJS参照（external binding）を保持します。
疎配列の巨大な `length` と辞書のキー数は、AOT/interpreterで同じ1,000,000の
要素数上限を超える場合に明示エラーにします。own enumerable keyを持たない
Map/Set/Date/RegExpなどは空辞書へ変換されます（浅いコピー契約の帰結）。
Symbolなど未分類のJS値は既存の `lnako_qjs_kind` と同じく `undefined` として扱います。
NULを含む辞書キーは既存の `convertObject` / `syncExternal` と同じ制限を継承します。
`JS実行` を含むJS→Nakoの文字列変換はWTF-8（孤立サロゲート可逆）に統一し、
Nako→JSの文字列・辞書キーもWTF-8で渡します。
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
`JSオブジェクト取得` の2引数形はlnako独自拡張で、公式の1引数形（グローバル名解決）は
interpreterで維持します。AOTは名前→グローバルslotの対応を持たないため、1引数形は
明示エラーにします。2引数形はレシーバがexternal bindingなら同じJS参照のプロパティ、
そうでなければ共有変換規則で作ったJSコピーのプロパティを取得し、戻り値は
配列・辞書を再帰変換してexternal bindingを付与します。Promise・関数・BigInt・
bytesは戻り値として明示エラーにし、AOT/interpreterで同じ文言にします。
`JSメソッド実行` は文字列レシーバをJSソースとして評価し、external
bindingのレシーバは同じJS参照、それ以外は共有変換規則のJSコピー上で実行します。
呼出し後はinterpreterと同じく、JS側の内容でexternal値（レシーバと実引数）の
Nakoコピーを再同期します。再同期は一時的な配列/辞書へ構築してから差し替えるため、
変換に失敗しても元のNako内容は失いません。
external bindingを持たない値でも共有変換規則でJSへ渡せるものは安全なフォールバックとし、
関数・BigInt・bytes・Promise・ネストした配列/辞書はAOT/interpreterで同じ文言の
明示エラーにします。ただしinterpreterのexternal値は`JS実行`由来の関数/BigInt/bytesを
要素に持ち得るため、そのようなコンテナを再同期・書き戻しする経路はinterpreterが
成功しAOTが明示エラーになります（AOTが生成するexternal値の要素は、`JS関数実行`の
浅い変換規則によりプリミティブ/配列/辞書に限られます）。値・Promise・callback・
GCの完全接続、関数値/BigInt/bytesの引数・戻り値への接続はfollow-up（Issue #55）
です。AOTの4命令は専用ABIを直接呼びますが、`LNAKO_DISPATCH_TRACE` の
dispatch traceへも記録します（route名はinterpreterと同じ `JS関数実行` など、
opcodeは65535、`command` には評価式ではなく命令名のみを入れます。評価式を
入れると利用者のスクリプト片がtraceへ漏れ、引用符でJSON行が壊れるためです）。
AOTの4命令はIR siteを持たないので `siteId` は null になります。

### AOT最小dispatchに合わせたinterpreterの意図的制限

AOTとinterpreterの観測を揃えるため、interpreterの`JSメソッド実行`と
2引数`JSオブジェクト取得`は、レシーバ・実引数をプリミティブ＋浅い配列/辞書＋
external bindingに限定し、戻り値のPromise・関数・BigInt・bytesを明示エラーに
します。これは公式cnako3の`nako_to_js`/`js_to_nako`（ネスト値や関数値をそのまま
扱う）より狭い意図的制限で、full接続はfollow-upです。1引数`JSオブジェクト取得`
（公式のグローバル名解決）はinterpreterで従来どおり動作し、AOTは変数bridgeを
持たないため明示エラーにします。

2引数形はC風呼び出し（`JSオブジェクト取得(OBJ, KEY)`）専用です。助詞呼出しの
スロット表は公式の1引数形（`NAMEの`）のままで、`is_variable`化はC風呼び出しの
個数検査だけに作用します。

external値の書き戻し・再同期はown enumerableプロパティを再構築するため、
JS側のgetter/setter（accessor property）は取得前の同期でNakoコピーのown data
propertyへ置き換わります（getterの副作用は観測しません）。
external値の再同期で作る辞書キーはWTF-8（孤立サロゲート可逆）です。
文字列はNako→JS・JS→Nakoの両方向でWTF-8（孤立サロゲート可逆）を使います。
配列の穴（sparse）は同期前後で保持し、辞書の同期は未変更プロパティを再代入せず、
変更されたキーだけをown data propertyとして定義します（`__proto__` もown data
propertyとして復元し、frozenオブジェクトの未変更プロパティで失敗しません）。
同期中に同じNakoオブジェクトが複数回現れた場合は同じJS参照を再利用し、JS側で
消えたキーは削除します。プロパティ取得後はgetter/jobによるレシーバ変更を
Nakoコピーへ再同期します。externalコンテナ内のNako bytesは書き戻せないため
明示エラーにします。JS結果の再帰変換とNako→JSの書き戻しは深さ64を上限とし、
超過は`QuickJsNestingTooDeep` の明示エラーにします（AOT/interpreter共通）。
疎配列の穴はJS→Nako・Nako→JSの両方向でpresenceとして保持し、往復後も
`hasOwnProperty` で穴と判定できます。配列の
index要素と`length`だけを同期し、JS配列のnamed property（`a.x=1`など）と
Nako側の`Array.properties`は相互に同期しません。外部関数値のgeneric呼出し
（`externalCall`）は結果をfull変換しますが、値・Promise接続の完全化はfollow-upです。
また、書き戻し途中で失敗したJSオブジェクトは一部だけ更新された状態になり得ます
（Nako側の再同期は一時領域へ構築してから差し替えるため、Nako側の内容は保持されます）。
またAOT compat runtimeは
interpreterのhost値bridgeを持たないため、`sys.__getSysVar`等はstrict stubとして
失敗し、`console`などinterpreterがbootstrapするグローバルは存在しません。

### npm bare import と ESM plugin

npm の ESM package は、lock と cache から解決した結果だけを使います。実行時に npm CLI や Node.js を起動しません。

- `build --compat-js`（embedded、既定）は payload format v8 に npm bare import の解決対応表を収録し、起動時の再コンパイルで cache やファイルシステムなしに復元します。lock と cache はビルド時に必要です。
- `--backend aot` は ESM manifest に path・source・所属 namespace・package root・bare alias を収録し、起動時に QuickJS へ module として登録します。bare import は compile 時に解決したモジュール source を生成物へ埋め込むため、実行先に npm・Node.js・cache は不要です。ビルド時に cache が欠けていると解決に失敗します。
- manifest は schema 2（`{"schema":2,"modules":[...],"packages":[...]}`）で、同梱した npm/ESM package の name・version・license と、root 相対の解決済み entry も収録します。`packages` は生成物の自己記述で、実行時の module 登録には使いません。
- `--sbom <path>` を併用すると、同梱 package の license 一覧を SPDX 2.3 形式の JSON として出力します。依存の出自で読む manifest を選び、npm instance は `package.json`（`license`、旧形式 object の `type`、古い `licenses` 配列は全選択肢を ` OR ` で連結）、path 依存 ESM package は `nako.toml` の `license` だけを使います（path 依存に開発用 `package.json` があっても混入しません）。`LICENSE`/`COPYING` 等のファイルがあれば SHA1（SPDX 2.3 §8.4 で必須）と SHA-256 付きの file record と `CONTAINS` 関係も出します。同梱 source の解析は行わないため、`licenseDeclared` は宣言値、`licenseConcluded` は常に `NOASSERTION` です。宣言が無い package も `NOASSERTION` です。SPDX の式として解釈できない宣言（`MIT/X11`、`(MIT`、`MIT ()` など）は推測せず `NOASSERTION` にして元の宣言を `comment` に残します（`UNLICENSED` は付与なしを意味する `NONE`）。`documentNamespace` は package・同梱 entry・license file・出力名の digest から作るため、同じ依存でも出力名が違えば別文書になります。出力は決定的です。
- `--sbom` は `--compat-js --backend aot` 専用です（他の組み合わせ、および生成物・入力 source と同じパスの指定は usage エラー）。通常 AOT は manifest も SBOM も生成しません。
- 同梱する package root の `package.json` / `nako.toml` が無い、または壊れている場合は、manifest と SBOM を不完全にせず build を失敗させます。
- ESM plugin の命令 `{namespace}__{命令}` は AOT の codegen で plugin dispatch として分類されます（native plugin の `native_plugin_paths` が空でも、ESM plugin の namespace を見て判定します）。以前は「変数に入った関数の呼出し」と誤分類され、存在しない変数の代入先を探して `UnknownAssignmentTarget` で build が失敗していました。
- **実行時の invoke は未対応**です。AOT 側の `hostInvoke` が null を返すため、ESM plugin 命令を AOT 生成物から実行すると `UnknownCommand` になります。plugin モジュール内部の bare import は起動時の bare alias 登録で解決され、`JS実行`・`JS関数実行` から plugin の関数を呼ぶ経路は動作します。参照 fixture は `tests/fixtures/package-plugin-npm/`（`aot-main.nako3`）。
- ESM-only の path 依存（`esm` だけを宣言したパッケージ）を lock で解決するには、`compat-js = true` を宣言した profile を置きます。lock と sync は、`default` が無ければ唯一の profile を自動で選びます。

参照 fixture の流れ:

```sh
LNAKO_NPM_REGISTRY=http://127.0.0.1:<port> lnako lock --package-cache-dir <cache>
lnako sync --offline --package-cache-dir <cache>
lnako run main.nako3 --compat-js
# AOT: 同梱依存だけで動く実行ファイルと、その license 一覧
lnako build aot-main.nako3 --compat-js --backend aot --offline -o ./aot-main --sbom ./aot-main.spdx.json
```

`tools/check_package_plugin_npm_e2e.mjs` は `.nako`・cache・`packages/`・`nako.toml` を退避した
project 外 cwd で AOT 実行ファイルだけを実行し、stdout が一致することを確認します。

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
