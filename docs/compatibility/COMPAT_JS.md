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

Windows x86_64 の compat AOT リンク向けに `src/compat/quickjs_win32_shim.{h,c}`
を追加し、QuickJS が参照する MinGW 固有の math/stdio/pthread/gettimeofday
シンボルを MSVC 静的 CRT でも解決できるよう Win32 API 実装へ置き換えています。
ただし **Windows x86_64 の compat AOT リンクは CI 検証待ち**です。Linux 上の
`x86_64-windows-gnu` クロスビルドと C ソースのコンパイルは確認できますが、
Windows x86_64 MSVC 環境でのリンク・実行はまだ検証していません。

通常AOT成果物にQuickJS/compat ABIが混入しないこと、compat AOT成果物が
QuickJSとESM情報を収録しESM呼出しに成功することは、生成物のシンボルと実行結果で
検査します。

```sh
node tools/check_aot_quickjs_separation.mjs --compiler zig-out/bin/lnako
```

AOT compat dispatchは `JS実行`・`JS関数実行`・`JSオブジェクト取得`・
`JSメソッド実行` の4命令です。`JS実行` は interpreter の full 変換と同じく、
プリミティブに加えて BigInt・JS 関数値・配列・辞書・循環参照を再帰的に Nako 値へ
写します。JS 関数値は AOT の関数オブジェクトとして保持し、external binding の
QuickJS 参照を GC sweep で1回だけ解放します。`JS関数実行` の第1引数は関数名
（文字列）に加えて、`JS実行` / `JSメソッド実行` が返した JS 関数値と Nako 関数値を
受け付けます（Nako 関数値は eval を挟まず `lnako_aot_function_call` で呼び出します）。
`JS関数実行` の実引数と戻り値も、`JS実行` と同じ full 変換です。配列・辞書は
ネスト・循環・疎配列を再帰変換し、BigInt・JS 関数値・Nako 関数 callback・bytes
（ByteBuffer は 0..255 の数値配列）を往復します。戻り値の配列・辞書は QuickJS 参照
（external binding）を保持し、後続の `JSオブジェクト取得` と `JSメソッド実行` が
同じJSオブジェクトを参照します。
external bindingはNako側ObjectがGCで回収されるときにQuickJS参照を1回だけ解放します
（通常AOT runtimeはQuickJSを参照しない汎用ハンドル）。
`JS関数実行` は第1引数の関数名（文字列）をglobal evalで解決し、引数コンテナの
規則は official と同じです（第2オペランドが配列なら要素を実引数へspreadし、
そうでなければ単一実引数）。各実引数は `JS実行` と同じ full 変換で、数値・文字列・
真偽値・null/undefined に加えて、ネストした配列・辞書、循環、疎配列、BigInt、
JS 関数値、Nako 関数 callback、ByteBuffer（0..255 の数値配列）を変換します。
同期変換できない Promise（コンテナ内の Promise を含む）と未対応型だけを、
AOT と interpreter で同じ文言（
`JS関数実行 does not support promises or unsupported argument types`）の明示エラーに
します。戻り値も同じ full 変換で、ネストした配列/辞書・関数値・BigInt・bytes
（TypedArray/ArrayBuffer/SharedArrayBuffer/DataView）を保持します。戻り値が
Promise のときは、`JS実行` の AOT 経路と同じく drain 後に `lnako_qjs_await` で
解決値を待ち、解決値も full 変換します。reject は reject 理由、pending は
`QuickJS promise is still pending` を明示エラーにし、無限待機しません
（official は Promise を await せず `[object Promise]` を返すため、この範囲だけ
意図的な差分です）。`then` が関数のオブジェクト（thenable）も bridge の
`lnako_qjs_kind` が Promise として扱うため、解決できない thenable は pending と
同じ明示エラーになります。プリミティブ要素の配列・辞書は `表示` の文字列化が
official と同じ（`1,2` / `[object Object]` / 空配列は空行）になることを fixture で
固定しています。疎配列の巨大な `length` と辞書のキー数は、AOT/interpreter で
同じ 1,000,000 の要素数上限を超える場合に明示エラーにします。
Symbolなど未分類のJS値は既存の `lnako_qjs_kind` と同じく `undefined` として扱います。
NULを含む辞書キーは既存の `convertObject` / `syncExternal` と同じ制限を継承します。
`JS実行` を含むJS→Nakoの文字列変換はWTF-8（孤立サロゲート可逆）に統一し、
Nako→JSの文字列・辞書キーもWTF-8で渡します。
interpreterで `JS実行` / `JS関数実行` が
返した配列・辞書は既存のJSオブジェクトを参照渡しし（Nako側の内容を書き戻す）、
Nakoネイティブ値は値コピーとしてJSへ渡ります。
呼出し時の `this` は official の `apply(null)` と同じ `null` です
（QuickJS bridge が `JS_NULL` を渡すため、strict 関数でのみ観測できます）。
Promise戻り値は解決値をawaitしてから変換しますが、エラー判定前にmicrotaskを
drainするため、呼び出した関数が登録した継続は実行されてから失敗します。
第1引数には関数値（`JS実行`が返したJS関数値やNako関数値）も渡せます。
JS関数値は同じJS参照を直接呼び、Nako関数値はNakoの呼出し規約で実行します。
`JSオブジェクト取得` の2引数形はlnako独自拡張で、公式の1引数形（グローバル名解決）は
interpreterで維持します。AOTは名前→グローバルslotの対応を持たないため、1引数形は
引き続き明示エラーです（AOT未対応）。2引数形はレシーバがexternal bindingなら同じ
JS参照のプロパティ、そうでなければ同期変換で作ったJSコピーのプロパティを取得し、
戻り値は配列・辞書を再帰変換してexternal bindingを付与します。レシーバ・実引数の
トップレベルはプリミティブと配列・辞書に限り、関数・BigInt・bytes・Promiseは
明示エラーにします。配列・辞書の中身はネストした配列/辞書・関数値・BigInt を
同期変換し、bytes（コンテナ内）と Promise（コンテナ内）だけを明示エラーにします。
戻り値のPromise・関数・BigInt・bytesはAOT/interpreterで同じ文言の明示エラーです。
### Nako→JS callback と GC

Nako の関数・クロージャを JS へ渡す経路（JS 関数値の呼出し引数、`{cb: fn}` /
`[fn]` のような入れ子、`JS実行` が返した JS 関数のコールバック引数）では、
`compat_js.zig` の `host_functions` が Nako 関数を世代付き ID で保持し、
`lnako_qjs_host_function` で QuickJS の JS 関数値を生成します。同じ
`*state.Object` は同じスロットを再利用し、クロージャは別 Object なので別
スロットになります。JS からの呼出しは `hostInvoke` が実引数を full 変換して
Nako 関数を呼び、呼出し後の実引数（Nako 側で変更した配列・辞書）を JS へ
書き戻してから戻り値を変換します。

#### インスタンス参照カウントと世代付き ID（Issue #278）

`lnako_qjs_host_function` は同じスロットから複数の JS 関数オブジェクトを
生成できます。`src/compat/quickjs_bridge.c` は各 JS 関数を `JSClassDef` の
`call` + `finalizer` を持つ callable として生成し、finalizer から
`LnakoQuickJsHostRelease(opaque, function_id, generation)` を1インスタンス
1回通知します。`src/compat/host_functions.zig` のテーブルは、成功した生成
ごとに `instances` を加算し、通知ごとに減算します。最後のインスタンスが
消えたスロットだけを tombstone として解放し、保持していた Nako 値
（クロージャと capture）を手放します。これにより、JS 側の参照が消えた
callback の capture は次の Nako GC で回収できます。

参照カウントの予約は C 関数生成より先に行います。スロット確保・検索の直後に
`acquire` して `instances` を +1 し、`lnako_qjs_host_function` が失敗した
場合だけ `errdefer` で同じ `(index, generation)` を `release` します。C 側の
関数生成中に QuickJS の GC やプロパティ操作で既存インスタンスの finalizer が
走っても、予約分の 1 がスロットを保護するため、直後の `acquire` が空振りして
無効な handle を返すことはありません。新規スロットなら失敗時の `1 -> 0` で
即解放され、既存スロットなら `N+1 -> N` へ戻ります。C 側の `committed` は
wrapper を返せたインスタンスだけ 1 になり、生成途中の `JS_FreeValue` から
重複した解放通知を送りません。

host 関数 class の `JSClassID` はプロセス共通の `static` 変数で採番します。
`JS_NewClassID` はポインタ先が非0なら同じ ID を返すため、engine の生成・破棄を
繰り返しても `js_class_id_alloc` を消費しません。各 runtime へは
`JS_IsRegisteredClass` を確認してから `JS_NewClass` し、`JS_NewContext` が
その時点の `rt->class_count` で `class_proto` を確保するため、class 登録は
`JS_NewRuntime` の後・`JS_NewContext` の前に済ませます。

スロット ID は密な配列 index ではなく `(index, generation)` の組です。
`function_id` は `uintptr_t`、`generation` は別の `uint64_t` として ABI に
渡すため、32bit 環境でも世代を index に詰めて切り捨てることがありません。
世代は 0 と `maxInt(u64)` を使わず単調増加し、尽きたら新規登録を失敗させます
（wrap しない）。解放後のスロットを再利用しても、古い世代の JS 関数は
`hostInvoke` の lookup に一致せず、新しいエントリを呼んだり解放したりしません。
生成途中で失敗したインスタンスは C 側の `committed` フラグが立たないため解放
通知を送らず、呼出し側は先予約した参照カウントを `errdefer` で戻すので、
既存インスタンスのカウントを汚しません。

`Function` 意味論を保つため、生成した関数は intrinsic な `Function.prototype`
を proto に持ち、own の `name` / `length` を定義します。`Function.prototype` は
`JS_NewContext` 直後（ユーザーコードや `install_host_bridge` より前）に
`JS_NewCFunction` の probe から `JS_GetPrototype` で一度だけ取得して engine に
保持し、`JS_FreeContext` の前に解放します。生成時に `globalThis.Function` を
名前引きしないため、ユーザーJSが `globalThis.Function = 0` にしたり getter を
仕込んだりしても、`typeof f === 'function'`、`f.call` / `f.apply` / `f.bind`、
`f.name` は通常の関数と同じです（`f instanceof Function` はグローバル
`Function` 自体を壊した場合はその限りではありません）。

#### GC 境界と teardown

`host_functions` は runtime の GC root ではないため、`Runtime.collect` の
`compat_trace` フックが生存スロットを毎回 mark します。`compatTrace` は Nako
GC の mark 中に走るため、そこで `WeakRef.deref` や `JS_RunGC` を呼びません。
QuickJS の finalizer から呼ばれる `hostRelease` も、スロットの参照カウント
減算と free list への連結だけを行い、QuickJS API や Nako GC を再入させません。
テスト・診断用に `lnako_qjs_run_gc(engine)` で QuickJS GC を明示実行できます。

`Runtime.deinit` と `lnako_aot_compat_deinit` のどちらが先に呼ばれても安全
です。テーブルを解放する前に `lnako_qjs_set_host_release(engine, NULL)` で
通知を解除するため、`JS_FreeContext` / `JS_FreeRuntime` の中で未解放 JS 関数の
finalizer が走っても、破棄済みのテーブルや runtime へ触れません。interpreter
側（`src/compat/quickjs.zig`）の `State` も同じ C bridge ABI と table を使い、
`State.deinit` で通知を解除してから engine 参照を落とします。

#### クロス GC の循環参照ポリシー

Nako クロージャが JS 値（external binding）を capture し、JS 側がその Nako
callback を保持する場合、参照の向きによって回収可能性が変わります。Nako GC は
JS→Nako 辺を見ず、QuickJS GC は Nako 側の external binding が持つ JS 参照を
root として扱うため、クロス GC の cycle collector は持ちません。

- **一方向（JS→Nako のみ）**: JS 側の最後の参照を落として QuickJS GC を実行
  すると finalizer が登録を解除し、続く Nako GC で closure・capture・
  external JS 値が回収されます。
- **真の双方向循環**: Nako closure が capture した JS オブジェクト `box` に、
  生成した同じ Nako callback を `box.cb = cb` として格納すると、
  `Nako closure → capture(external box) → box.cb(JS host function) →
  host_functions → Nako closure` の循環になります。Nako 側が external binding
  を保持している限り QuickJS は `box` を回収できず、`box.cb` も生存するため
  host 関数テーブルは closure を root し続けます。したがって `globalThis` から
  `box` を落として `lnako_qjs_run_gc` を実行しても循環は teardown まで保持され、
  `runtime.deinit` と `lnako_aot_compat_deinit`（どちらが先でも）で安全に
  解放・回収されます。
- **循環の一辺を切る**: `box.cb = null` などで JS→Nako 辺を明示的に切れば、
  QuickJS GC の finalizer が登録を解除し、続く Nako GC で closure と capture
  （external JS 値）を実行中に回収できます。JS 側を弱参照にする場合も同じです。

この方針は AOT の「真のクロスGC循環をteardownまで保持する」テストと
「クロスGC循環の辺を切ると実行中に回収する」テストで固定しています。従来の
「JSとNakoの循環参照をteardownまで保持する」テストは capture が `()=>7` で
JS→Nako の戻り辺がなく一方向だったため、真の循環は上記のテストで検証します。
通常 AOT では `compat_trace` / `compat_deinit` が null のままで、
`runtime_core.zig` は `compat_js.zig` を静的に参照しません
（`check_aot_quickjs_separation.mjs` が通常 AOT 成果物の QuickJS 非依存を
検査します）。

callback 経路は `SyncState.full_values = true` のため、BigInt と ByteBuffer
（0..255 の JS 配列）も Nako↔JS で往復します。Nako callback が失敗した場合、
`hostInvoke` は Nako 側の未捕捉例外を解消して QuickJS へ `null` を返します。
QuickJS はこれを `InternalError` にするため、JS の `try/catch` は callback 例外を
捕捉できます。JS が捕捉しなかった場合だけ、呼出し元の `fail` がエラーを報告します。
`Promise.resolve(...).then(cb)` の microtask は `JS関数実行` の drain/await 中に
実行され、Nako callback の戻り値が解決値になります。

`JSメソッド実行` は文字列レシーバをJSソースとして評価し、external
bindingのレシーバは同じJS参照、それ以外は共有変換規則のJSコピー上で実行します。
呼出し後はinterpreterと同じく、JS側の内容でexternal値（レシーバと実引数）の
Nakoコピーを再同期します。再同期は一時的な配列/辞書へ構築してから差し替えるため、
変換に失敗しても元のNako内容は失いません。
external bindingを持たない値でも同期変換でJSへ渡せるものは安全なフォールバックとし、
トップレベルの関数・BigInt・bytes・Promise と、コンテナ内の bytes・Promise は
AOT/interpreter で同じ文言の明示エラーにします。external コンテナの再同期と
callback 経路は full 変換で、`JS実行` 由来の関数・BigInt・bytes も要素として
保持・往復します。値・Promise・callback・GCの接続はIssue #55 Unit 2で実装済みです。
AOTの4命令は専用ABIを直接呼びますが、`LNAKO_DISPATCH_TRACE` の
dispatch traceへも記録します（route名はinterpreterと同じ `JS関数実行` など、
opcodeは65535、`command` には評価式ではなく命令名のみを入れます。評価式を
入れると利用者のスクリプト片がtraceへ漏れ、引用符でJSON行が壊れるためです）。
AOTの4命令はIR siteを持たないので `siteId` は null になります。

### AOTに合わせたinterpreterの意図的制限

AOTとinterpreterの観測を揃えるため、interpreterの`JSメソッド実行`と
2引数`JSオブジェクト取得`は、レシーバ・実引数のトップレベルをプリミティブと
配列・辞書（external binding を含む）に限定し、トップレベルの関数・BigInt・
bytes・Promise を明示エラーにします。配列・辞書の中身はネストした配列/辞書・
関数値・BigInt を同期変換し、コンテナ内の bytes と Promise だけを明示エラーに
します。戻り値のPromise・関数・BigInt・bytesも明示エラーです。`JS関数実行` の実引数・
戻り値は full 変換で、同期変換できない Promise と未対応型だけを明示エラーに
します。`JS実行` の full 変換、JS 関数値の保持・呼出し、Nako→JS callback は
#55 Unit 2 で接続済みです。
1引数`JSオブジェクト取得`（公式のグローバル名解決）はinterpreterで従来どおり動作し、
AOTは変数bridgeを持たないため引き続き明示エラーにします（AOT未対応）。

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
Nakoコピーへ再同期します。callback以外のexternalコンテナ同期ではNako bytesを
書き戻せないため明示エラーにします。JS結果の再帰変換とNako→JSの書き戻しは深さ64を上限とし、
超過は`QuickJsNestingTooDeep` の明示エラーにします（AOT/interpreter共通）。
疎配列の穴はJS→Nako・Nako→JSの両方向でpresenceとして保持し、往復後も
`hasOwnProperty` で穴と判定できます。配列の
index要素と`length`だけを同期し、JS配列のnamed property（`a.x=1`など）と
Nako側の`Array.properties`は相互に同期しません。外部関数値のgeneric呼出し
（`externalCall`）は結果をfull変換し、Nako関数・クロージャを実引数に渡すと
`hostFunction` / `hostInvoke` 経由でJSから同期呼出しできます。
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
- **実行時の invoke も対応しました**（Issue #55）。AOT の compat runtime は plugin module を評価して `__lnako_commands` を作り、同じ manifest の module を埋め込み interpreter の `program.javascript_modules` へ引き継ぎます。interpreter は初期化時に `installModules` を実行するため、`{ns}__{命令}` の呼出しは `lnako_aot_esm_plugin_call` → `callExternalCommand` → 登録済み plugin 命令へ解決されます。dispatch trace の route は `esm-plugin` です。
- 参考: plugin モジュール内部の bare import は起動時の bare alias 登録で解決され、`JS実行`・`JS関数実行` から plugin の関数を呼ぶ経路は動作します。参照 fixture は `tests/fixtures/package-plugin-npm/`（`aot-main.nako3`）。
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
