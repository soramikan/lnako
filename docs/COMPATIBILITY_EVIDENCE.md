# 命令カタログ証拠レイヤー

`compat/v3.7.24/evidence.json`は、標準cnako 527 entryをカタログID単位で
既存fixtureへ関連付ける台帳です。通常のfixture関連付けは実行結果やdispatch接続を証明しません。
追跡中の証拠は、macOS arm64の単一実行環境で、`tests/oracle/dispatch-cases.json`が`native-cut-commands`を基礎に生成する明示fixture `native-dispatch-commands`についてcompile manifest、Interpreter/AOT trace、公式差分を
同一fixture・siteで突き合わせられた一意名331 entryが`trace-confirmed-unattested`です（既存14命令に型変換系16命令、算術・比較系15命令、配列系12命令、文字列系21命令、論理・ビット・集約系20命令、表系14命令、数学系36命令、文字変換系4命令、置換系2命令、出現1命令、形式・文字種判定系7命令、値・状態系12命令、文字列合成・URL系12命令、JSON・要素数系9命令、幅変換系8命令、配列callback系4命令、配列構造系7命令、辞書・hash key系7命令、配列スタック・複製・連番系5命令、パス系5命令、礼節系6命令、動的実行系2命令、標準出力系6命令、デバッグ待機系1命令、デバッグ表示・配列シャッフル系2命令、システム関数存在系1命令、実行時間計測系1命令、ハテナ関数設定・実行系2命令、システムメタデータ一覧系5命令（システム関数一覧取得、プラグイン一覧取得、モジュール一覧取得、助詞一覧取得、予約語一覧取得）、Node HTTP body系1命令（POSTデータ生成）、Node状態・ファイル情報系3命令（AJAXオプション設定、ファイルサイズ取得、ファイル情報取得）、Nodeファイル存在系2命令（存在、フォルダ存在）、Node基本ファイルI/O系3命令（開、読、バイナリ読）、Node文字コードファイルI/O系4命令（SJISファイル読、SJISファイル保存、EUCファイル読、EUCファイル保存）、Nodeファイル操作系5命令（フォルダ作成、保存、ファイル列挙、全ファイル列挙、ファイル削除）、Nodeファイルcopy・move系4命令（ファイルコピー、ファイル上書コピー、ファイル移動、ファイル上書移動）、Node cwd変更系2命令（カレントディレクトリ変更、作業フォルダ変更）、CSV系7命令、秒待系8命令、Promise成功系3命令、Promise処理系2命令、Promise束ね系1命令、Node host情報・環境系10命令、Node一時・乱数系3命令（一時フォルダ作成、ランダムUUID生成、ランダム配列生成）、Node archive state系1命令（圧縮解凍ツールパス変更）、ハッシュ値計算1命令、Node文字コード系4命令、日時書式系1命令、時間・乱数系4命令、グローバル関数一覧取得1命令、Node console・assertion系2命令（コンソールクリア、ASSERT等）を加えた範囲）。さらに`native-scalar-system-constants`の24件は、17件のglobal readと7件のtyped literalを、専用manifest／Interpreter・AOT trace／公式4経路比較で`lnako.static-constant-evidence.v2`へ別namespaceとして記録する。`native-string-system-constants`の24件は公式sourceをoracleにした比較で、`lnako.static-constant-evidence.v2`へ別namespaceとして記録する。公式生成JavaScriptには初期`名前空間`の既知差があるため、string fixtureでは公式source・lnako run・AOT O0の一致と公式生成JavaScriptの成功を記録する。`native-array-system-constants`の2件は、共有配列を変更してから表示する公式source・生成JavaScript・lnako run・AOT O0の一致を同じ証拠形式で記録し、`native-datetime-era-data`の`plugin_system`／`command-0227` global read 1件は、同名`plugin_datetime` entryと区別する明示catalog IDを含む公式source・公式生成JavaScript・`lnako run`・AOT O0の一致を同じ証拠形式で記録する。`native-node-archive-constant`の`plugin_node` global read 1件は公式カタログの初期値`7z`を読む公式source・公式生成JavaScript・`lnako run`・AOT O0の一致を同じ証拠形式で記録する。`native-node-command-line-constants`の`plugin_node` global read 3件は、argv由来の非空条件を公式source oracle・lnako run・AOT O0で比較し、同じ証拠形式で記録する。`native-node-http-initial-constants`の5件は、公式カタログ上の`plugin_node`（`AJAXオプション`）と`plugin_httpserver`（`HTTPメソッド`、`GETデータ`、`POSTデータ`、`FILESデータ`）を同じfixtureでcatalog plugin identity付きで検証する。公式CLI・公式生成JavaScript・`lnako run`・AOT O0の初期値比較では、`AJAXオプション`が空文字、HTTPサーバー未取り込みの4定数が`null`となる公式境界を保持する。`native-node-mother-path`の定数1件は、同じfixtureに含まれる関数呼出しを除外し、`母艦パス`のglobal readだけを公式4経路とInterpreter/AOT trace・manifestで確認する。`native-caniuse-agents`の`plugin_caniuse` global read 1件は、19キーの`ブラウザ名変換表`を公式source・`lnako run`・AOT O0で一致させる。公式生成JavaScriptはcaniuse pluginをstandaloneへ登録しないため生成自体は成功してもstdoutが異なり、この既知差は`docs/COMPATIBILITY_QUIRKS.md`で記録する。`native-system-promise-reject`の`plugin_promise` global read 1件は、Promise生成後に更新された`そ`を公式4経路とInterpreter/AOT trace・manifestで確認する。追跡中のJSONにはattestationを記録しないため、ローカルの`verified`は0件で、合計394 entryが`trace-confirmed-unattested`、133 entryが`unverified`です。

`ASSERT等`は公式マニュアルの詳細説明が準備中で、成功時の戻り値と保留Promiseの排出順は短い説明だけからは確定できません。固定v3.7.24の公式CLIでは、Promise callbackを登録した後に`ASSERT等(1,1)`を実行するとcallback群を先に排出してから`undefined`を出力します。lnakoのInterpreter/AOTは同期dispatchの`undefined`を先に出力してからcallback群を排出するため、この混在順序は未実装境界として`docs/COMPATIBILITY_QUIRKS.md`へ分離しました。canonical `native-dispatch-commands`では`ASSERT等`をPromise登録より前に置き、同一siteのInterpreter/AOT trace・compile manifest・公式4経路を一致させています。さらにpipe出力で副作用が観測できない`コンソールクリア`も同じcanonical fixtureへ追加しました。

AOT差分artifactとdispatch証拠は入力・実行物・結果のSHA-256を内包します。各OS内では公式source・生成JavaScript・lnako run・AOT O0の
stdout/stderr hashを一致させますが、OS間のdispatch意味比較では、パス区切りなどOS依存の出力hashを含めず、fixture・route結果状態・catalog/site構造を比較します。
CIのmain push/workflow_dispatchでは、3正式OSのdispatch JSONを公式`actions/attest`のmulti-subject artifact attestationへ結び付け、公式`gh attestation verify`で
署名、SLSA predicate、workflow identity、OIDC issuer、対象commit、3 OSのdigestを検証します。検証成功時だけCI一時出力のcatalog evidenceを`verified`として生成し、追跡中のmacOS単体JSONは変更しません。
未attest、fork PR、権限不足、対象commit・workflow・digest不一致では`trace-confirmed-unattested`のまま昇格しません。

### 外部成果物の履歴固定

Actions artifactの保持期限後も外部検証できるよう、run `32983175945`（証拠対象commit `1ee47232d34711abaddb28038218258232ac3800`）の成果物を
`compat/v3.7.24/attestations/32983175945/`へ追跡している。`manifest.json`で3正式OSのdispatch JSON、各digest、dispatch-attestation、Sigstore bundle、
historical catalogのdigestとworkflow identityを固定し、`node tools/check_tracked_dispatch_attestation.mjs`が禁止field、対象commit、bundleの
in-toto subject、SLSA predicate、GitHub Actions workflow identityを検査する。bundleの署名を暗号学的に再検証する場合は、保存したbundleを
公式`gh attestation verify`へ同じ厳格なidentity引数で渡す。固定されたhistorical catalogの`verified: 4`は現在commitの台帳へ自動反映せず、
追跡中の`compat/v3.7.24/evidence.json`は`verified: 0`、`trace-confirmed-unattested: 394`、`unverified: 133`を記録する。catalog再生成時の`--historical-commit`は
この明示的な履歴検査でだけ対象commitとの差異を許可し、明示的な非canonical outputを必須にする（通常のsync検査は、証拠生成元のfixture/source commitとの一致、またはその祖先から証拠・台帳・文書・CIとdispatch生成器以外の検証器だけを記録した後続commitを要求し、canonical output保護は緩めない）。target commitとこの履歴固定を追加する後続commitを混同しない。

### 証拠記録commitの追従

dispatch checkerは実行前のcleanなcommitを証拠の出所として記録します。生成したJSONをtracked台帳へ記録する署名commit以降も、証拠生成元が現行HEADの祖先で、差分pathが証拠・派生台帳・互換文書・CI・dispatch生成器以外の検証器のallowlistに限定される場合に限り、証拠の出所を維持したfollow-upとして受理します。製品ソース、fixture、catalog、dispatch生成器が後続commitで変わる場合は受理せず、同じfixtureでdispatch証拠を再生成します。

## 生成と検証

```sh
node tools/sync_compat_evidence.mjs --generate
node tools/sync_compat_evidence.mjs --check
# 公式差分を含む最小dispatch証拠を一度だけ生成（絶対パス、既存ファイル不可）。
# NADESIKO3_ORACLEを指定する場合もmarker・CLI・実行treeの固定SHA-256がlockと一致する必要がある
node tools/check_dispatch_trace.mjs --evidence-output /absolute/path/dispatch-evidence.json
# 静的定数をfixtureごとに公式4経路、Interpreter/AOT trace、専用manifestで検証
node tools/check_static_constant_evidence.mjs --no-build --fixture native-scalar-system-constants --evidence-output /absolute/path/static-constant-evidence.json
node tools/check_static_constant_evidence.mjs --no-build --fixture native-string-system-constants --evidence-output /absolute/path/static-string-constant-evidence.json
node tools/check_static_constant_evidence.mjs --no-build --fixture native-array-system-constants --evidence-output /absolute/path/static-array-constant-evidence.json
node tools/check_static_constant_evidence.mjs --no-build --fixture native-datetime-era-data --evidence-output /absolute/path/static-datetime-era-constant-evidence.json
node tools/check_static_constant_evidence.mjs --no-build --fixture native-node-archive-constant --evidence-output /absolute/path/static-node-archive-constant-evidence.json
node tools/check_static_constant_evidence.mjs --no-build --fixture native-node-command-line-constants --evidence-output /absolute/path/static-node-command-line-constant-evidence.json
node tools/check_static_constant_evidence.mjs --no-build --fixture native-node-mother-path --evidence-output /absolute/path/static-node-mother-path-constant-evidence.json
node tools/check_static_constant_evidence.mjs --no-build --fixture native-node-http-initial-constants --evidence-output /absolute/path/static-node-http-initial-constant-evidence.json
node tools/check_static_constant_evidence.mjs --no-build --fixture native-caniuse-agents --evidence-output /absolute/path/static-caniuse-agents-constant-evidence.json
node tools/check_static_constant_evidence.mjs --no-build --fixture native-system-promise-reject --evidence-output /absolute/path/static-promise-reject-constant-evidence.json
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
- `compat/v3.7.24/static-constant-evidence.json`（`native-scalar-system-constants`のglobal read 17件＋typed literal 7件の実行証拠）
- `compat/v3.7.24/static-string-constant-evidence.json`（`native-string-system-constants`のglobal read 24件の実行証拠）
- `compat/v3.7.24/static-array-constant-evidence.json`（`native-array-system-constants`のglobal read 2件の実行証拠）
- `compat/v3.7.24/static-datetime-era-constant-evidence.json`（`native-datetime-era-data`の`plugin_system`／`command-0227` global read 1件の実行証拠）
- `compat/v3.7.24/static-node-archive-constant-evidence.json`（`native-node-archive-constant`の`plugin_node` global read 1件の実行証拠）
- `compat/v3.7.24/static-node-command-line-constant-evidence.json`（`native-node-command-line-constants`の`plugin_node` global read 3件の実行証拠）
- `compat/v3.7.24/static-node-mother-path-constant-evidence.json`（`native-node-mother-path`の`plugin_node` global read 1件の実行証拠）
- `compat/v3.7.24/static-node-http-initial-constant-evidence.json`（`native-node-http-initial-constants`の`plugin_node`／`plugin_httpserver` global read 5件の実行証拠）
- `compat/v3.7.24/static-caniuse-agents-constant-evidence.json`（`native-caniuse-agents`の`plugin_caniuse` global read 1件の実行証拠）
- `compat/v3.7.24/static-promise-reject-constant-evidence.json`（`native-system-promise-reject`の`plugin_promise` global read 1件の実行証拠）

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
全394件（AOT 299件、Interpreter 99件、QuickJS 9件）です。配列のcustom `__proto__`による辞書prototype chainの直接参照・表property・存在判定・ToPrimitiveは`native-system-array-custom-prototype-properties`で比較します。辞書の`toString` / `valueOf`によるToPrimitiveのhint順序・フォールバック・失敗は`native-system-dictionary-to-primitive`で比較し、Buffer・関数・Promiseのown `toString` / `valueOf`によるToPrimitiveは`native-system-object-to-primitive-host-properties`で比較し、配列のown `toString` / `valueOf`による文字列hint・数値hintは`native-system-array-to-primitive`で比較し、64要素未満と64要素以上の配列カスタムソートにおけるV8のrun判定・binary insertion・TimSortの比較順は`native-system-array-callback-order`と`native-system-array-callback-order-large`で比較します。表ソート・表数値ソートの64要素以上におけるV8 TimSortの比較順は`native-system-table-sort-callback-order-large`と`native-system-table-sort-nan-comparator-boundary`で比較します。幅変換命令の辞書・prototypeカスタム`substring`/`charAt`/`split`呼出しは`native-system-width-custom-string-methods`で比較し、Buffer/Uint8Arrayのraw receiverエラーは`native-system-width-byte-buffer-receiver`で比較します。正規表現のUnicode Script/Script_Extensions propertyと/v基本照合は`native-system-regexp-unicode-script-extensions`、`native-system-regexp-unicode-all-scripts`、`native-system-regexp-unicode-ignore-case`、`native-system-regexp-unicode-v-basic`、`native-system-regexp-unicode-v-invalid-flags-error`、`native-system-regexp-unicode-word-boundary`、`native-system-regexp-unicode-set-operations`、`native-system-regexp-unicode-lookbehind-boundary`と`native-system-regexp-lookbehind-capture-order`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較します。`plugin-node-native-archive`は圧縮・解凍4命令を含み、`plugin-node-process`と関連fixtureはNodeプロセス7命令を含み、`plugin-node-file-callbacks`はファイル完了callback、進捗、停止を含み、InterpreterとAOT O0〜O3で実行・生成物を検証します。`plugin-node-http-*`はHTTP clientのloopback通信を含み、AOT対象7 fixtureをO0〜O3で実行・比較します。疎配列のsort・数値変換・reverse・shuffleは`native-system-array-sparse-ordering`でpresence境界を比較し、splice系は`native-system-array-sparse-splice`で削除元と戻り値のpresenceを比較し、参照・配列足・範囲コピーは`native-system-array-sparse-copy-reference-concat`でslice/concatとJSON往復のpresence境界を比較し、配列要素作成の複製元配列holeは`native-system-array-fill-sparse-clone`でpresence境界と複製独立性を比較し、配列要素作成のBuffer/Uint8Array/ArrayBuffer JSON複製は`native-system-array-fill-byte-buffer-json-clone`でオブジェクト化と複製独立性を比較し、表ソートは`native-system-table-sparse-sort`で行配列の並べ替えと最上位配列のpresence境界を比較し、表数値ソートのBigInt同士・BigInt/Number混在の型境界は`native-system-table-numeric-sort-bigint-error`と`native-system-table-numeric-sort-mixed-bigint-error`で公式エラーを7経路比較し、表列取得・表ピックアップ系は`native-system-table-sparse-map-filter`でmap/filterのhole境界を比較し、表列挿入・削除・合計は`native-system-table-sparse-foreach-slice`でforEachと行sliceのhole境界を比較し、表重複削除は`native-system-table-sparse-unique`で最上位holeのraw index参照診断を比較し、匿名関数のname/length propertyは`native-system-table-function-properties`で比較し、Object/Array/String/Functionとprimitiveの標準prototype property読み出しは`native-system-table-inherited-properties`で比較し、辞書のカスタム`__proto__`から継承した`length`の表列数は`native-system-table-inherited-length`と`native-system-table-byte-buffer-inherited-length`で比較します。Bufferの表列挿入slice共有とTypedArray/ArrayBufferのcopy境界は`native-system-table-byte-row-slice-alias`で比較し、Bufferの表正規表現ピックアップslice共有は`native-system-table-regexp-buffer-slice-alias`と`native-system-table-regexp-inner-sparse-slice`で比較し、Buffer/Uint8Arrayのscalar propertyと代表的prototype methodは`native-system-byte-buffer-property`で比較し、Buffer/Uint8Array/ArrayBufferの直接property参照は`native-system-byte-buffer-direct-properties`で比較し、Buffer/Uint8Arrayの`.buffer`が共有backing ArrayBuffer viewとなること、ArrayBuffer自身の`.buffer`が`undefined`となることは`native-system-byte-buffer-backing`と`native-system-byte-buffer-backing-identity`で比較します。byte bufferから抽出したBuffer `slice`関数のreceiver未束縛エラーは`native-system-byte-buffer-method-calls`で比較します。辞書・配列・関数の`辞書キー存在`/`ハッシュキー存在`がown propertyに加えて標準prototype propertyを確認することは`native-system-dictionary-inherited-properties`で比較し、Buffer/Uint8Array/ArrayBufferのown index・`length`・標準prototype propertyの存在判定は`native-system-dictionary-byte-buffer-properties`で比較し、辞書・配列の`参照`/`配列参照`における標準prototype propertyとown値優先は`native-system-reference-inherited-properties`で比較します。辞書array-likeの先頭一致でAOTが`length`分をeager展開しないことは`native-system-string-array-from-dictionary-lazy-length`で比較します。object-literalの`__proto__`から辞書の`length`と数値添字を継承する系列化、およびJSONでprototypeをown entryから除外する境界は`native-system-string-array-from-inherited-properties`で比較します。辞書に対する`配列切取`のown/prototype lookup、truthy判定、継承property非削除は`native-system-array-cut-inherited-dictionary-properties`で比較します。命令のfixture coverageは`paired` 523 entry、
Node Bufferのenumerable prototype property 95件の順序・`parent`・`offset`・内容値は`native-system-dictionary-buffer-enumerable-properties`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較します。
`native-system-byte-buffer-null-prototype`は、Buffer/Uint8Array/ArrayBufferへ`__proto__ = NULL`を設定した後の標準property遮断、数値添字、表property、表列数、辞書／ハッシュキー存在を公式CLI・生成JavaScript・Interpreter・LLVM AOT O0〜O3で比較します。
`native-node-path-components`はdrive-relative path、drive root、UNC root、Windows namespace（`\\?\\` / `\\.\\`）を含むWindows形式のbasename/dirname入力を含み、公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3で比較します。`native-node-path-type-errors`はnullish・number・boolean・BigInt・Array・Object・function・Buffer・Uint8Array・ArrayBufferの非文字列入力について、Node 24の引数ラベルと`Received`文面を同じ7経路で比較します。Windows targetでのnamespace pathと特殊なUNC形式の実行確認は`TODO: node-path-win32-boundary`として分離します。
`native-node-current-directory-error`は、未存在の日本語pathに対する`ENOENT: no such file or directory, chdir '<cwd>' -> '<path>'`診断を公式CLI・生成JavaScript・Interpreter・LLVM AOT O0〜O3で比較し、hostスイートの`tools/check_node_current_directory_errors.mjs`でも同じ作業フォルダから再確認します。
`native-system-string-array-from-arraybuffer-arraylike`は、ArrayBufferへownの`length`と数値プロパティを設定した場合に、公式`Array.from`のarray-like分岐がそれらを読む境界を公式CLI・生成JavaScript・Interpreter・LLVM AOT O0〜O3で比較します。素のArrayBufferは`length`が未定義のため空列のままです。
疎な最上位表のhole・nullish行に対する`length` property read診断は`native-system-table-sparse-length-errors`で`表列数`・`表行列交換`・`表右回転`を比較します。
同一ユーザー関数の`prototype` object identityと、そのown `constructor` back-referenceは`native-system-table-inherited-properties`で公式CLI・生成JavaScript・Interpreter・LLVM O0〜O3を比較します。
`interpreter-only` 0 entryです。execution evidenceは`verified` 0、
`trace-confirmed-unattested` 394、`unverified` 133です。
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

空幅atomの量指定を含む正規表現境界は`native-system-regexp-zero-width-quantifier`で公式CLI・生成JavaScript・Interpreter・LLVM AOT O0〜O3を比較します。非Unicode modeのlegacy octal escape（class内の`\\1`・`\\12`・`\\123`と外側の`\\07`）、およびcapture数以下ならbackreference、未定義captureならlegacy octalまたは数字リテラルへfallbackするclass外decimal escapeは`native-system-regexp-legacy-octal-escapes`で同じ7経路を比較します。

可変長lookbehindの貪欲・非貪欲量指定は後ろ側のatomから逆向きに評価され、captureの結果と複数一致時の探索順へ影響します。`native-system-regexp-lookbehind-capture-order`で公式CLI・生成JavaScript・Interpreter・LLVM AOT O0〜O3を比較し、lookbehind内部のbackreferenceでは、逆向き評価時点で未確定のcaptureを空文字として扱う規則も含めて比較します。さらに複雑なcapture副作用順序は`TODO: regexp-backtracking-edge`として未検証のまま分離します。

`native-system-dictionary-inherited-enumeration`は、custom辞書prototype chainの列挙順・shadowing・対応値を公式CLI・公式生成JavaScript・`lnako run`・LLVM AOT O0〜O3で比較するfixtureです。これによりfixture inventoryは全394件（AOT 299件、Interpreter 99件、QuickJS 9件）になりました。

`native-toml-commands`は表・配列テーブル・インライン表・文字列・数値の標準範囲を比較し、`native-toml-temporal-values`は日付、時刻、local datetime、offset datetimeのDate系値と、秒・ミリ秒・`T`への正規化を公式CLI・公式生成JavaScript・`lnako run`・LLVM AOT O0〜O3で比較します。公式マニュアルと命令説明からは依存ライブラリ由来の型と正規化を判断できないため、[`tests/fixtures/toml-temporal-probe.nako3`](../tests/fixtures/toml-temporal-probe.nako3)には正常系に加えて時刻単独のオフセット付き値を仕様調査用probeとして保存しています。後者は公式`smol-toml` v1.8.0が受理するものの`31T22:32:00.`という壊れたserializer結果になる不具合候補であり、正常な互換仕様や成功証拠へ混ぜません。`native-toml-temporal-values`のfixture実行はAOT dispatch証拠ではなく、外部署名のない現在の`evidence.json`へentryを自動昇格させません。Dateのメソッド、完全な`ToPrimitive`、異常入力の全範囲は`TODO: toml-temporal-values`として継続します。

`plugin_markup`については、[`plugin-markup-html-script`](../tests/oracle/supplemental-plugin-cases.json)へraw HTMLと`javascript:`リンクを追加し、公式CLI・公式生成JavaScript・lnakoの出力一致を追加確認します。これは公式の危険なHTML出力を再現する回帰fixtureであり、sanitize済みであることや安全なHTML変換を証明するものではありません。命令カタログの短い説明からはこの境界を判断できないため、利用者向けの安全上の注意と、`marked`依存の仕様・不具合候補を`docs/COMPATIBILITY_QUIRKS.md`へ分離して記録します。`script`/`style` raw blockの分類など未比較の入力をこのfixtureから推測せず、別のprobeで扱います。

## 同名命令

漢数字の指数・全角数字・小数・空白・Infinity・基数接頭辞と算用数字の非標準表記は、`native-kansuji-aot-generated-boundaries`で公式CLI・Interpreter・LLVM AOT O0〜O3を比較します。公式standalone生成JavaScriptはplugin登録を行わないため、oracleは公式CLIに固定し、残る全生成境界は`TODO: aot-kansuji-generated-boundaries`として扱います。

正規表現の構文エラー文言は、`native-system-regexp-js-error-text`でUnicode時の単独量指定括弧、vフラグの集合演算子右辺欠落、クラス内の不正property・named escape、連続集合演算子を公式CLI・生成JavaScript・Interpreter・LLVM AOT O0〜O3で比較します。Unicode modeの多桁decimal backreferenceの成功と、capture数を超えた場合の`Invalid escape`は`native-system-regexp-unicode-decimal-backreferences`と`native-system-regexp-unicode-decimal-backreference-error`で同じ7経路を比較します。別構文の未検証なJavaScriptエラー文言は`TODO: regexp-js-error-text`として残します。

同名異pluginの31組62 entryのうち、61 entryは`identityResolution: "ambiguous-name"`です。
同じfixtureへ命令名で割り当てられていても、命令名だけではcatalog IDやpluginを識別できず、
ID単位の実行証拠にはなりません。その理由は各entryへ明記され、実行証拠状態も`unverified`のままです。
例外として`元号データ`の`plugin_system`側`command-0227`だけは、fixture定義と証拠entryの明示catalog IDが一致するため、
`identityResolution: "explicit-catalog-id"`として静的定数の実行証拠を記録します。`plugin_datetime`側`command-0807`は同じfixtureから推測せず、未証拠のままです。

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
`切取`・`範囲切取`・`配列結合`・`LEN`・`文字列変換`・`JSON変換`・`表ソート`・`表数値ソート`・`CHR`・`表示`の
Interpreter/AOT実dispatchと、同名system命令よりNode routeが優先される
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
sync検証時はgit取得失敗を拒否し、dirty=falseの証拠は記録commitが現行HEADと一致するか、上記の一段のmetadata follow-upであることも確認します。
dirty=trueの場合は未コミット差分の内容までは証明しないため、
これは単一環境のunattested証拠であり、3環境の互換性や署名済みverified証拠を意味しません。

`tools/check_dispatch_coverage.mjs`は、既存のcanonical dispatch証拠を変更せずに、命令系統別の到達範囲を監査します。
plugin-system・system-runtime・standard-plugin・supplemental-pluginの命令関連fixture、Nodeプロセス／ファイルcallbackのAOT成功fixture、
および`native-cut-commands`を対象に、
公式source、実行可能な公式生成JavaScript、Interpreter、AOT O0を比較し、traceの成功siteとcompile manifestの対応を確認します。
この監査が命令関連付けとして数えるのは、AOT成功result、Interpreter成功result、site ID、opcode、route、catalog IDが揃う一意なsiteだけです。
`fixture.commands`に名前があるだけ、検証器がglobal read trace／manifestを確認していない定数読出し、同名異pluginをrouteだけで推定しただけのentryは実行証拠へ数えず、
レポートの`associationWithoutDispatch`、`unresolvedObservedSites`、`unobservedNativeEntryIds`へ分離します。
ただし`native-scalar-system-constants`については、公式source・公式生成JavaScript・`lnako run`・AOT O0の4経路が同じ結果になり、AOTの`lnako.aot.global-manifest.v1`／`lnako.aot.literal-manifest.v1`とInterpreter/AOTのschema 1 traceが、global read 17 siteとtyped literal 7 siteをそれぞれ指すことを専用checkerで確認します。`native-string-system-constants`は公式sourceをoracleとし、`lnako run`・AOT O0の一致、公式生成JavaScriptの実行成功、`lnako.aot.global-manifest.v1`、Interpreter/AOTのschema 1 `global-read` traceで24 siteを確認します。公式生成JavaScriptは初期`名前空間`の初期化経路が異なるため、string fixtureの比較ではこの既知差をoracle間の不一致として保持します。`native-array-system-constants`は共有配列を変更してから表示する公式source・公式生成JavaScript・`lnako run`・AOT O0の一致と、AOTの`lnako.aot.global-manifest.v1`、Interpreter/AOTのschema 1 `global-read` traceで2 siteを確認します。`native-node-http-initial-constants`は、公式カタログのplugin identityを命令ごとに検証し、`plugin_node`の`AJAXオプション`と`plugin_httpserver`の`HTTPメソッド`・`GETデータ`・`POSTデータ`・`FILESデータ`を、公式4経路の初期値比較と専用global manifest／schema 1 traceで5 site確認します。`native-caniuse-agents`は、公式source・`lnako run`・AOT O0で`plugin_caniuse`の19キー`ブラウザ名変換表`と同じ参照を確認しますが、公式生成JavaScriptはimport済みpluginをstandaloneへ登録しないため生成成功後もstdoutが異なります。`native-system-promise-reject`は、Promise生成後に更新された`plugin_promise`の`そ`を公式4経路とglobal manifest／schema 1 traceで1 site確認します。
この63 entryはbuiltin dispatchとは別の10ファイルの`lnako.static-constant-evidence.v2`へ記録し、`trace-confirmed-unattested`へ反映します。fixture内の`はい`・`いいえ`・`真`・`偽`・`オン`・`オフ`・`NULL`の7 entryは型付きliteral loweringで、global readとは別の命令経路です。scalar fixtureは公式4経路のstdout/stderr一致、string fixtureは公式source・lnako run・AOT O0の一致と公式生成JavaScriptの成功、array fixtureは共有配列変更後の公式4経路のstdout/stderr一致、datetime era fixtureは同名異pluginのうち明示catalog IDで固定した`plugin_system`／`command-0227`の公式4経路のstdout/stderr一致、Node archive fixtureは初期値`7z`の公式4経路のstdout/stderr一致、Node command-line fixtureはargv由来の非空条件を公式source oracle・lnako run・AOT O0で一致させ、Node mother path fixtureは同じfixtureの関数呼出しを除外した`母艦パス`のglobal readを公式4経路で一致させ、Node HTTP initial fixtureは`plugin_node`の`AJAXオプション`と`plugin_httpserver`のHTTPサーバー4定数を公式4経路で一致させ、caniuse fixtureは公式source・`lnako run`・AOT O0のstdout/stderrとglobal-read siteを一致させ、Promise定数fixtureはPromise生成後の`そ`の値とglobal-read siteを一致させ、ならびに全fixtureの命令siteを確認していますが、外部attestationはまだありません。caniuseの公式生成JavaScriptのstdout差は、証拠のoracleにせず既知の公式経路差として保持します。`plugin_datetime`／`command-0807`は同じfixtureから推測せず未証拠に残します。
公式生成JavaScriptがstandalone host／plugin登録を持たないfixture、また公式sourceとAOT O0が一致しない
`system-runtime-execution-and-debug`は、明示したroute制限・AOT gapとしてレポートし、成功coverageへ混入させません。
出力schemaは`lnako.dispatch-coverage.v1`で、`kind`は`sampled-unattested-dispatch-audit`です。これは`verified`やattestation済みcatalog evidenceではありません。

```sh
# 既存出力を上書きしない絶対パスへ監査レポートを生成
node tools/check_dispatch_coverage.mjs --no-build --output /absolute/path/dispatch-coverage.json
```

既定の監査はCI時間を抑えるため30 fixtureを対象にします（Nodeプロセス／ファイルcallbackのAOT成功fixtureを含みます）。標準命令の実行siteを広げて監査する場合は、
`--include-native`を追加すると、`native-cases.json`のcommand-bearing全200件（既定の`native-cut-commands`を除く追加候補199件）を候補に加えます。
このうちnative側の意図的なエラー・プロセス終了29件と、Nodeの外部host／圧縮toolを使うfixtureは`excludedFixtures`へ理由付きで残したまま成功経路から除外します。
`native-cut-commands`は既定範囲に含まれるため、追加されるnative成功fixtureは170件となり、合計200 fixtureを検査します。
ファイルを生成・変更するfixtureだけrouteごとの作業ディレクトリを分離し、カレントディレクトリや母艦パスを観測するfixtureは全routeで同じ作業ディレクトリとsource pathを使います。
この拡張監査もcanonical evidenceや`verified`昇格の代わりではなく、出力JSONの`fixtureSelection`と`excludedFixtures`へ対象範囲を記録します。

CIのAOT suiteは3正式OSごとにこのレポートを`lnako-dispatch-coverage-*` artifactへ保存します。artifactの保存は到達範囲の追跡用であり、
現行のdispatch evidence attestationや`verified`昇格の入力ではありません。

## AOT compile manifest

`LNAKO_COMPILE_MANIFEST`へ絶対JSONLパスを指定すると、AOT buildは
`lnako.aot.builtin-manifest.v1`形式のmanifestを新規作成します。既存ファイルは上書きしません。
先頭に`pre-opt` header、続けてLLVM emitterへ渡す前の各builtin call、buildとlinkの成功後に
件数付き`complete` recordを書きます。schema名は維持したままheaderの`siteIdEncoding`とentryの
`siteId`を追加しており、site IDを使う検証器はこの追加フィールドを必須にします。途中で失敗したbuildは部分manifestを削除します。

各callはソース上の命令名、numeric opcode、canonical opcode、LLVM emitter route、site ID、関数名、ソース位置だけを含み、
引数・値・ポインタは含みません。builtin manifestの対象はbuiltin callであり、定数やグローバル読出し、利用者関数・動的呼出しは対象外です。静的な定数は、裸のglobal参照なら`LNAKO_GLOBAL_MANIFEST`／`LNAKO_GLOBAL_TRACE`、typed literalなら`LNAKO_LITERAL_MANIFEST`／`LNAKO_LITERAL_TRACE`を使う`lnako.static-constant-evidence.v2`で別経路として扱います。
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

## Static/global constant evidence

公式の`定数`entryは一種類の実行形式ではない。ソース中の裸の名前をglobalから読むentryと、
字句解析時にboolean/nullのtyped literalへlowerされるentryが同じカタログへ掲載される。そのため、
`LNAKO_COMPILE_MANIFEST`と`LNAKO_DISPATCH_TRACE`だけでは、定数entryの実行siteを証明できない。
`LNAKO_GLOBAL_MANIFEST`はAOTの最適化前`load_global`を`lnako.aot.global-manifest.v1`として記録し、
`LNAKO_GLOBAL_TRACE`はInterpreter/AOTの成功した`global-read`をschema 1で記録する。
`LNAKO_LITERAL_MANIFEST`はtyped literalを`lnako.aot.literal-manifest.v1`として記録し、
`LNAKO_LITERAL_TRACE`はInterpreter/AOTの`literal`実行をschema 1で記録する。いずれも引数・値・ポインタを
保存せず、builtin dispatch traceとは別namespaceのsite IDを使います。

`node tools/check_static_constant_evidence.mjs --no-build`をfixtureごとに実行すると、固定fixture
`native-scalar-system-constants`、`native-string-system-constants`、`native-array-system-constants`、`native-datetime-era-data`、`native-node-archive-constant`、`native-node-command-line-constants`、`native-node-http-initial-constants`、`native-node-mother-path`、`native-caniuse-agents`、`native-system-promise-reject`について、公式source、公式生成JavaScript、`lnako run`、
AOT O0のstdout/stderr、global/literal manifest、Interpreter/AOT traceを突き合わせます。scalarのglobal read 17件＋typed literal 7件、stringのglobal read 24件、arrayのglobal read 2件、datetime eraの`plugin_system`／`command-0227` global read 1件、Node archiveのglobal read 1件、Node command-lineのglobal read 3件、Node HTTP initialのglobal read 5件をcatalog IDへ解決し、
`compat/v3.7.24/static-constant-evidence.json`、`compat/v3.7.24/static-string-constant-evidence.json`、`compat/v3.7.24/static-array-constant-evidence.json`、`compat/v3.7.24/static-datetime-era-constant-evidence.json`、`compat/v3.7.24/static-node-archive-constant-evidence.json`、`compat/v3.7.24/static-node-command-line-constant-evidence.json`、`compat/v3.7.24/static-node-http-initial-constant-evidence.json`、`compat/v3.7.24/static-node-mother-path-constant-evidence.json`、`compat/v3.7.24/static-caniuse-agents-constant-evidence.json`、`compat/v3.7.24/static-promise-reject-constant-evidence.json`へ
それぞれ`lnako.static-constant-evidence.v2`として記録しています。attestationはまだ付いていないため、
この63件は`trace-confirmed-unattested`であり、`verified`ではありません。`native-caniuse-agents`は公式source・`lnako run`・AOT O0の一致をoracleとし、公式生成JavaScriptはcaniuse pluginをstandaloneへ登録しないため生成成功後もstdoutが異なる既知差を記録します。`native-system-promise-reject`は公式4経路の一致と、Promise生成後に更新された`そ`のglobal readを記録します。`native-datetime-era-data`は同名異pluginの`plugin_system`／`command-0227`だけを明示catalog IDで証拠化し、`plugin_datetime`／`command-0807`を同じfixtureから推測しません。

同じfixtureの`はい`・`いいえ`・`真`・`偽`・`オン`・`オフ`・`NULL`の7件は、公式の値と一致する
型付きliteralへlowerされるため、global-read siteを持ちません。これは定数実装の失敗を意味せず、
global readとliteralを別証拠へ分ける設計上の境界です。literal専用manifest／traceはあるものの、
外部署名attestationはまだなく、全527 entryの実行証拠を完了扱いにはしません。

`native-system-reference-byte-buffer-properties`は、Buffer/Uint8Arrayの数値添字・`length`・`buffer`と、`buffer`から得たArrayBufferの`byteLength`・欠損添字を`参照`/`配列参照`で読む境界について、公式CLI・生成JavaScript・`lnako run`・LLVM AOT O0〜O3を比較します。fixture inventoryは全394件（AOT 299件、Interpreter 99件、QuickJS 9件）へ更新しています。
