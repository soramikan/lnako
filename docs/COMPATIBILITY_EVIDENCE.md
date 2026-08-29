# 命令カタログ証拠レイヤー

`compat/v3.7.24/evidence.json`は、標準cnako 527 entryをカタログID単位で
既存fixtureへ関連付ける台帳です。通常のfixture関連付けは実行結果やdispatch接続を証明しません。
追跡中の証拠は、macOS arm64の単一実行環境で、明示fixture `native-cut-commands`についてcompile manifest、Interpreter/AOT trace、公式差分を
同一fixture・siteで突き合わせられた一意名4 entryが`trace-confirmed-unattested`です。追跡中のJSONにはattestationを記録しないため、ローカルの`verified`は0件で、残り523 entryも`unverified`です。

AOT差分artifactとdispatch証拠は入力・実行物・結果のSHA-256を内包します。CIのmain push/workflow_dispatchでは、3正式OSのdispatch JSONを
公式`actions/attest`のmulti-subject artifact attestationへ結び付け、公式`gh attestation verify`で署名、SLSA predicate、workflow identity、
OIDC issuer、対象commit、3 OSのdigestを検証します。検証成功時だけCI一時出力のcatalog evidenceを`verified`として生成し、追跡中のmacOS単体JSONは変更しません。
未attest、fork PR、権限不足、対象commit・workflow・digest不一致では`trace-confirmed-unattested`のまま昇格しません。

### 外部成果物の履歴固定

Actions artifactの保持期限後も外部検証できるよう、run `32983175945`（証拠対象commit `1ee47232d34711abaddb28038218258232ac3800`）の成果物を
`compat/v3.7.24/attestations/32983175945/`へ追跡している。`manifest.json`で3正式OSのdispatch JSON、各digest、dispatch-attestation、Sigstore bundle、
historical catalogのdigestとworkflow identityを固定し、`node tools/check_tracked_dispatch_attestation.mjs`が禁止field、対象commit、bundleの
in-toto subject、SLSA predicate、GitHub Actions workflow identityを検査する。bundleの署名を暗号学的に再検証する場合は、保存したbundleを
公式`gh attestation verify`へ同じ厳格なidentity引数で渡す。固定されたhistorical catalogの`verified: 4`は現在commitの台帳へ自動反映せず、
追跡中の`compat/v3.7.24/evidence.json`は`verified: 0`、`trace-confirmed-unattested: 4`を維持する。catalog再生成時の`--historical-commit`は
この明示的な履歴検査でだけ対象commitとの差異を許可し、明示的な非canonical outputを必須にする（通常のsync検査の現行HEAD一致制約とcanonical output保護は緩めない）。target commitとこの履歴固定を追加する後続commitを混同しない。

## 生成と検証

```sh
node tools/sync_compat_evidence.mjs --generate
node tools/sync_compat_evidence.mjs --check
# 公式差分を含む最小dispatch証拠を一度だけ生成（絶対パス、既存ファイル不可）。
# NADESIKO3_ORACLEを指定する場合もmarker・CLI・実行treeの固定SHA-256がlockと一致する必要がある
node tools/check_dispatch_trace.mjs --evidence-output /absolute/path/dispatch-evidence.json
# CIで生成された3 OS artifactを公式GitHub CLIで検証し、一時catalog evidenceを生成
node tools/verify_dispatch_attestation.mjs --directory /absolute/path/dispatch-evidence --bundle /absolute/path/attestation-bundle.json --output /absolute/path/dispatch-attestation.json --catalog-evidence /absolute/path/evidence-verified.json --repository soramikan/lnako --commit <40-hex-commit> --source-ref refs/heads/main --workflow soramikan/lnako/.github/workflows/ci.yml
```

生成元は次の固定資料です。

- `compat/upstream.lock.json`（タグ、commit、命令カタログSHA-256の正本）
- `compat/v3.7.24/command_list.json`（公式全1,145命令）
- `compat/v3.7.24/matrix.json`（全命令の分類）
- `compat/v3.7.24/standard-cnako.json`（標準cnako 527 entry）
- `compat/v3.7.24/implemented.json`（実装台帳）
- `tests/oracle/*.json`（fixtureの明示`commands`と実在ID）
- `compat/v3.7.24/dispatch-evidence.json`（checkerが生成した同一fixture/siteの実行証拠）

`upstream.lock.json`の`nadesiko3.oracleIdentity`にはoracle build 4のCLIとmarkerのSHA-256に加え、marker自身を除く
実行ツリー全体の決定的tree hashも固定しています。tree hashは相対POSIXパス、entry種別、通常ファイルのサイズと
内容SHA-256をパス順に結合し、絶対パス・mtime・modeは含めません。symlinkはproduction treeに残っていれば拒否します。production prune後に
npmが生成する全階層の`.bin`と`.package-lock.json`を明示削除した`node_modules`を含みます。lockには正式3環境
（darwin-arm64、linux-x64、win32-x64）へ同一値を登録し、未登録のOS/archは安全側に拒否します。各OSでの初回再計算一致が
完了条件であり、macOS以外をこのローカル実行だけで検証済みとは扱いません。CIキャッシュキーにもrunner archと
固定archive hashの短縮値を含めます。
`tools/setup_oracle.mjs`はcache hitでもこれらの固定値を実体と照合し、`compare_native_oracle.mjs`と
`check_dispatch_trace.mjs`も同じ固定値に一致しないoracleを受理しません。

生成・検証時には、baselineとSHA-256を`upstream.lock.json`へ直接照合し、
standard各entryをmatrixの同一IDについて`name`、`plugin`、`status`など全共通フィールドで照合します。

## 関連付けの規則

fixtureのソース本文から命令名を推測することはしません。関連付けのoriginは次の二つだけです。

- `fixture.commands`: fixtureが明示した命令名
- `implemented.tests`: 実装台帳が記録し、`tests/oracle`に実在するfixture ID

`aotFixtureIds`は`native-cases.json`に実在するIDだけ、`compatJsFixtureIds`は
`compat-js-cases.json`に実在するIDだけを収録します。未解決の実装台帳IDは収録せず、
`unresolvedTestIds`へ残します。

`fixtureCoverageState`は実行成功を意味しません。

- `paired`: interpreterとAOTの明示fixtureがある
- `interpreter-only`: interpreterだけに明示fixtureがある
- `aot-only`: AOTだけに明示fixtureがある
- `none`: 明示fixtureがない
- `compat-js-only`: compat-js fixtureだけに明示関連付けがある

### interpreter-onlyの分類

`compat/v3.7.24/interpreter-only-classification.json`は、現在の`evidence.json`から
`fixtureCoverageState=interpreter-only`のentryだけをplugin・category・type単位へ分類した派生台帳です。
各entryのcatalog ID、命令名、interpreter fixture ID、AOT fixture ID、
`executionEvidenceState`も保持するため、次にAOT fixtureを追加する対象を命令系統ごとに選べます。
この分類は実装完了、AOT実行、公式等価性、attestation済みの`verified`を意味しません。

`plugin-httpserver-all`は、既存のInterpreter比較に加えて、純LLVM AOT O0〜O3の実通信比較を行うfixtureです。HTTPクライアントは`tools/compare_node_http_oracle.mjs`でloopback実通信を比較し、`plugin-node-http-callbacks`、`plugin-node-http-options-and-promises`、`plugin-node-http-async-values`、Discord、失敗処理の7 fixtureをAOT O0〜O3へ昇格しています。

現行HEADでは、明示`commands`を追加した既存AOT fixtureと数学・日時・caniuse・漢数字・CSV・TOML・マークアップ・比較・表・敬語・標準出力・プラグイン管理・ASYNC・システムカタログ・Node/AJAX初期定数・LINE Notify廃止エラー・Node終了・Node強制終了登録・Nodeファイル存在・Nodeファイルサイズ・Nodeファイル情報・NodeファイルI/O・Node同期ファイル操作・Nodeファイルcallback・Nodeコンソールクリア・Node文字コード変換・Node文字コードサポート判定・Node標準入力行取得・コールバック・全取得・Node HTTPデータ生成・Node HTTPクライアント・Node AJAXオプション設定・Node AJAX失敗時設定・Nodeネットワークアドレス・Nodeディレクトリ値・Node母艦パス・Node一時フォルダ作成・Nodeファイルコピーデフォルト動作・Nodeハッシュ名一覧・Node暗号（ハッシュ値・UUID・乱数配列）・Node圧縮解凍ツールパス・Nodeプロセス（同期／非同期shell実行とOSランチャー）・エラー発生・実行時間計測・デバッグ表示・既定ハテナ実行・カスタムハテナ実行・デバッグブレイクポイント待機・タイマー待機・タイマー（単発・周期・停止）・Promise連鎖・Promise束ね・Promise待機・動的ソース実行fixtureを含めて、fixture inventoryは
全321件（AOT 230件、Interpreter 96件、QuickJS 9件）です。`plugin-node-native-archive`は圧縮・解凍4命令を含み、`plugin-node-process`と関連fixtureはNodeプロセス7命令を含み、`plugin-node-file-callbacks`はファイル完了callback、進捗、停止を含み、InterpreterとAOT O0〜O3で実行・生成物を検証します。`plugin-node-http-*`はHTTP clientのloopback通信を含み、AOT対象7 fixtureをO0〜O3で実行・比較します。疎配列のsort・数値変換・reverse・shuffleは`native-system-array-sparse-ordering`でpresence境界を比較し、splice系は`native-system-array-sparse-splice`で削除元と戻り値のpresenceを比較し、参照・配列足・範囲コピーは`native-system-array-sparse-copy-reference-concat`でslice/concatとJSON往復のpresence境界を比較し、表ソートは`native-system-table-sparse-sort`で行配列の並べ替えと最上位配列のpresence境界を比較し、表列取得・表ピックアップ系は`native-system-table-sparse-map-filter`でmap/filterのhole境界を比較し、表列挿入・削除・合計は`native-system-table-sparse-foreach-slice`でforEachと行sliceのhole境界を比較し、匿名関数のname/length propertyは`native-system-table-function-properties`で比較し、Object/Array/String/Functionとprimitiveの標準prototype property読み出しは`native-system-table-inherited-properties`で比較します。Bufferの表列挿入slice共有とTypedArray/ArrayBufferのcopy境界は`native-system-table-byte-row-slice-alias`で比較し、Bufferの表正規表現ピックアップslice共有は`native-system-table-regexp-buffer-slice-alias`で比較し、Buffer/Uint8Arrayのscalar propertyと代表的prototype methodは`native-system-byte-buffer-property`で比較し、Buffer/Uint8Arrayの`.buffer`が共有backing ArrayBuffer viewとなること、ArrayBuffer自身の`.buffer`が`undefined`となることは`native-system-byte-buffer-backing`で比較します。辞書・配列・関数の`辞書キー存在`/`ハッシュキー存在`がown propertyに加えて標準prototype propertyを確認することは`native-system-dictionary-inherited-properties`で比較し、Buffer/Uint8Array/ArrayBufferのown index・`length`・標準prototype propertyの存在判定は`native-system-dictionary-byte-buffer-properties`で比較し、辞書・配列の`参照`/`配列参照`における標準prototype propertyとown値優先は`native-system-reference-inherited-properties`で比較します。辞書array-likeの先頭一致でAOTが`length`分をeager展開しないことは`native-system-string-array-from-dictionary-lazy-length`で比較します。命令のfixture coverageは`paired` 523 entry、
Node Bufferのenumerable prototype property 95件の順序・`parent`・`offset`・内容値は`native-system-dictionary-buffer-enumerable-properties`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較します。
`interpreter-only` 0 entryです。execution evidenceは`verified` 0、
`trace-confirmed-unattested` 4、`unverified` 523のままです。
fixtureの関連付けを変更した場合は、次で派生台帳の生成と検査を行います。

```sh
node tools/check_interpreter_only_classification.mjs --generate
node tools/check_interpreter_only_classification.mjs --check
```

`executionEvidenceState`は別の状態です。`verified`へ進めるには、dispatch証拠に記録されたcatalog IDが
一意名として解決でき、明示fixtureの同一siteについてcompile manifest、Interpreterの成功result、
AOTの成功attempt/result対、公式source・生成JavaScript・lnako run・AOT O0の終了結果が全て一致し、外部attestationが検証できなければなりません。
attestationがない場合は`trace-confirmed-unattested`に留めます。
この条件を満たさないentryは、fixtureが存在しても`unverified`のままです。

## 同名命令

同名異pluginの31組62 entryは`identityResolution: "ambiguous-name"`です。
同じfixtureへ命令名で割り当てられていても、命令名だけではcatalog IDやpluginを識別できず、
ID単位の実行証拠にはなりません。その理由は各entryへ明記され、実行証拠状態も`unverified`のままです。

## 実dispatch trace

`LNAKO_DISPATCH_TRACE`へ絶対JSONLパスを指定すると、InterpreterとAOTランタイムは
引数・値・ポインタを含まない固定メタデータだけを記録します。未指定時はファイルを作成せず、
標準出力、標準エラー、終了コードを変えません。既存ファイルは上書きせず、新しいパスだけを受理します。
traceのschemaは2です。

- Interpreter: `callBuiltin`の同期完了だけを`dispatch-result`として記録し、`seq`で各callを識別して実際に成功・失敗したplugin routeを区別する
- AOT: builtin、切取、正規表現ABI、直接表示への到達を`dispatch-attempt`と`dispatch-result`の対で記録する
- 静的呼出しには`siteId`（`0x`＋16桁小文字hex）を付け、同じsiteの反復実行でも`callId`は毎回変える。InterpreterとAOTはこのsite IDで照合できる
- AOTの`dispatch-result`は対応するattemptと同じ`callId`・site・opcode・command・routeを持ち、`success`で成否を示す
- AOTのbuiltin・切取・正規表現・直接表示の`success`は固定値ではなく、各ABI開始時と完了時のfailure epochで決定する。直接表示の結果ABIも成否引数を持たず、ランタイムが開始epochを参照するため、過去から残ったpending exceptionを後続callへ誤帰属しない
- AOTの命令名: ソース上の別名ではなく、LLVM ABIへ渡ったcanonical opcode名
- 正常終了: 最終行に`trace-end`と`dropped: 0`を記録し、途中欠落を検出可能にする

書込み失敗と`runtime_deinit`を通らない異常終了はプログラム自体の意味を変えません。
その場合は`trace-end`が得られないため、検証ハーネスが実行基盤エラーとして拒否します。

`node tools/check_dispatch_trace.mjs`はtrace有無の実行結果一致、JSONL構造、
`切取`・`範囲切取`のInterpreter/AOT実dispatchと、同名system命令よりNode routeが優先される
`ファイル名抽出`・`パス抽出`を固定fixtureで検証します。
通常実行は作業ツリーを変更せず、`--evidence-output`を指定した場合だけ公式source・生成JavaScriptとの
差分を追加確認し、絶対パスへ新規証拠を生成します。`sync_compat_evidence.mjs --check`はその証拠の
baseline、fixture source hash、catalog identity、site、runtime成否を再検証します。`--attestation`を併用する場合は`--attestation-bundle`も必須で、
metadataのschema、workflow identity、対象commit、3正式OS、現行JSONのdigest、bundle SHA-256を確認したうえで、公式`gh attestation verify`による
署名検証を再実行します。metadata JSONだけでは`verified`へ昇格できません。外部attestationを指定しない通常の結果は
`trace-confirmed-unattested`に留まります。未実行のNode route、
O1〜O3、pre/post-opt IR、同名異plugin entryはverifiedへ昇格しません。
また、sync検証は`equivalent`フラグを信用せず、4 routeのstdout/stderr SHA-256が公式sourceと一致すること、
trace eventCountが正でsite数を包含することも確認します。Windowsネイティブ実行のCRLFと公式Node経路のLFを同じ出力として比較できるよう、
4 routeのstdout/stderrだけはCRLFをLFへ正規化してから
SHA-256を記録します。trace・compile manifestのraw hashは正規化しません。
dispatch証拠schema v2のprovenanceには
OS、Node、公式oracle marker／CLI／archiveのhash、実行前lnako binaryのhash、git commit／dirty、
一時raw trace／manifestのhashだけを保存し、source本文・ローカルパス・raw本文は保存しません。
sync検証時はgit取得失敗を拒否し、dirty=falseの証拠だけは記録commitが現行HEADと一致することも確認します。
dirty=trueの場合は未コミット差分の内容までは証明しないため、
これは単一環境のunattested証拠であり、3環境の互換性や署名済みverified証拠を意味しません。

## AOT compile manifest

`LNAKO_COMPILE_MANIFEST`へ絶対JSONLパスを指定すると、AOT buildは
`lnako.aot.builtin-manifest.v1`形式のmanifestを新規作成します。既存ファイルは上書きしません。
先頭に`pre-opt` header、続けてLLVM emitterへ渡す前の各builtin call、buildとlinkの成功後に
件数付き`complete` recordを書きます。schema名は維持したままheaderの`siteIdEncoding`とentryの
`siteId`を追加しており、site IDを使う検証器はこの追加フィールドを必須にします。途中で失敗したbuildは部分manifestを削除します。

各callはソース上の命令名、numeric opcode、canonical opcode、LLVM emitter route、site ID、関数名、ソース位置だけを含み、
引数・値・ポインタは含みません。定数やグローバル読出し、利用者関数・動的呼出しは対象外です。
site IDはsemantic bindingが固定builtinと解決した全呼出しについて、lowering時に関数IDと関数内の静的呼出し順から決定します。
利用者関数、名前が衝突した利用者関数、native/JS pluginの動的命令には付けません。manifestはそのうち
AOT ABIで処理できるsubsetだけを証拠化し、manifest内の重複はbuildエラーにします。
emitter routeは`builtin`・`cut`・`regexp`・`timer`・`promise`・`debug-display`・`hatena-default`・`hatena-configure`・`node-interrupt`・`archive-tool-path`・`ajax-options`・`ajax-onerror`・`node-file-io`・`node-stdin-lines`・`direct-display`のABI分類であり、
Interpreterの`plugin_system`・`plugin_node`等のplugin routeとは異なります。
また、これはNako最適化前のdispatch予定を示す資料であり、LLVM最適化後にcallが残ったことや、
実行時の成功を単独では証明しません。実行時traceと公式差分結果を別に照合する必要があります。

manifest自体にはcatalog IDやpluginを記録しません。検証器が標準527 entryと照合する際は、
命令名が一意な場合だけIDを自動解決します。同名命令はrouteが一致するだけでは
公式plugin由来を一般には証明できません。現在のスモークでは、InterpreterがNodeをsystemより先に
探索することを実測した`ファイル名抽出`・`パス抽出`だけNode側IDへ解決し、system側やdatetime別名は
未解決のまま扱います。verifiedへ使うcatalog IDとsiteの対応は生成済み
`dispatch-evidence.json`の明示associationだけを受理し、ソース本文から推測しません。
