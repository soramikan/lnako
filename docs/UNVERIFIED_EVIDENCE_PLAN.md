# `unverified` 89件の証拠化計画（U14完了時点）

## 目的と基準

この文書は、なでしこ3 v3.7.24（upstream `aa18c7e640523938c680958fe731418cc6f7a58f`）の標準cnako 527 entryについて、実装済み機能を過大評価せず、`compat/v3.7.24/evidence.json`の`unverified`を実行証拠へ接続するための計画である。89件の初期残件をU01〜U22へ分解し、2026-09-02のU14完了後は次の状態にある。

| 状態 | entry数 | 意味 |
|---|---:|---|
| `verified` | 0 | 3正式OSの署名付きattestationまで揃った現在HEADの証拠 |
| `trace-confirmed-unattested` | 483 | 公式差分、Interpreter/AOT trace、compile manifest等は揃うが、外部署名attestation前 |
| `unverified` | 44 | 実装・fixtureの存在だけではcatalog ID単位の実行証拠にならない残件 |

`native: 523`という分類、fixtureの存在、Interpreterだけの成功、artifactの生成は、AOT verifiedや`trace-confirmed-unattested`を意味しない。各単位を完了扱いにするのは、この文書の共通完了条件と台帳検査が同時に通った場合だけとする。最終的な目標は、まず`trace-confirmed-unattested 527 / unverified 0`、その後に3正式OSの外部署名attestationを含む`verified`へ進むことである。

## 現在の進捗（2026-09-02）

U01（`エラー発生`、`__DEBUG`）は完了した。cleanな`7eb6a96d9d44909d7051a2017d7c35f525a70739`で再生成したdispatch coverageは32 fixture・1,698 site・311 native entryを含み、`native-system-error-raise`の4 throw failure siteと`native-system-debug`の1 success siteを、それぞれ明示catalog ID付きでInterpreter trace・AOT manifest/runtime traceへ接続している。`エラー発生`は通常のbuiltin opcodeではなくSSA throw terminatorの監査専用routeであり、期待失敗を成功siteとして数えない。

同じclean HEADで10件のstatic constant artifactも再生成し、U01時点の`sync_compat_evidence.mjs --generate`の結果は`verified 0 / trace-confirmed-unattested 440 / unverified 87`となった。U02（`ナデシコ`、`ナデシコ続`）も完了した。cleanな`eb9949499c6f55329da3c5199543fb334cd41817`で再生成した33-fixture dispatch coverageは1,703 site・313 native entryを含み、`native-system-dynamic-execution`の`ナデシコ` 2 site（`command-0057`）と`ナデシコ続` 2 site（`command-0058`）を公式source・Interpreter・AOT O0の同一結果、compile manifest、runtime traceへ接続した。公式生成JavaScript単体の終了コード1は既存のstandalone system host登録差であり、P0の既知route差として記録する。

U02のdispatch generator変更を`eb99494`へ、33-fixtureを受理する同期検査変更を`b68ec28`へ分離し、後者のfollow-up規則でclean artifact provenanceを検査した。U03ではOS別argvを本番経路で構築してから安全なhost adapterで最終launcher生成だけを捕捉し、`エクスプローラー起動`のdarwin/linux期待失敗をfixture policyへ追加した。`c7c6501`を証拠生成元とする34-fixture dispatch coverageは1,707 site・315 native entryを含み、U03の2 entryをcatalog evidenceへ接続する。U04ではglobal readだけでなくwriteも同じaccess namespaceのsite IDで記録し、`global-binding-evidence.json`へ`ファイルコピーデフォルト動作`の5 access（read/write/read/write/read）を固定した。U05では標準カタログ上は`関数`である3命令を括弧なしで参照するfixtureについて、OS依存の値を固定文字列にせずhost Context／AOT directory initializerから供給し、3つのglobal-read siteを`directory-binding-evidence.json`（`lnako.global-binding-evidence.v2`）へcatalog ID別に固定した。公式plugin_node命令一覧（https://nadesi.com/v3/doc/index.php?plugin_node=&show=）と固定upstream実装（https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/src/plugin_node.mts#L897-L939）を参照し、公式source・公式生成JavaScript・lnako Interpreter・AOT O0を比較した。U05完了後の`sync_compat_evidence.mjs --generate`は実測で`verified 0 / trace-confirmed-unattested 448 / unverified 79`を返したが、U04/U05とも3正式OSの外部署名attestationを含む`verified`ではない。

U06では`plugin-node-native-archive-hermetic`を追加し、`解凍`・`解凍時`・`圧縮`・`圧縮時`の4 entryを公式source・公式生成JavaScript・lnako Interpreter・LLVM AOT O0〜O3で比較した。公式helperが実際に組み立てる`7z a -r ... -y`／`7z x ... -o... -y`のtool-path、非同期callback、出力ファイルを保ったまま、fixture専用のstored-ZIP helperへ置換し、ZIP entry名・ディレクトリ・サイズ・CRC32・内容hashという意味結果を比較している。raw ZIP byte列や任意の外部7z実装、3正式OSのattestationを証明するものではない。`check_dispatch_coverage.mjs`の`archiveHelper` policy、35 fixture・1,727 site・322 native entryの監査、canonical dispatchのInterpreter 944 event／Node 42 event／AOT manifest 946件／runtime 1,888 eventを経て、`sync_compat_evidence.mjs --generate`は実測で`verified 0 / trace-confirmed-unattested 452 / unverified 75`を返した。helperはテスト時の明示markerに限り有効で、通常の外部ツール経路を変更しない。

U07では`plugin-node-exit-code`、`plugin-node-interrupt`、`plugin-node-exit-japanese-alias`を追加し、`プロセス終`・`強制終了時`・`終了`の3 entryを`compat/v3.7.24/expected-exit-evidence.json`へ分離して記録した。公式source・公式生成JavaScript・lnako Interpreter・LLVM AOT O0〜O3の終了コードと出力hashを比較し、終了直前のdispatch result、AOT attempt/result、`terminalReason`、`trace-end`、O0 compile manifestのsiteを同一catalog IDで検証する。`プロセス終`は終了コード7、`終了`は0、`強制終了時`はPOSIXの実SIGINT callback後に0である。SIGINTは非同期timerのin-flight dispatchを最大1件残し得るため、その境界をartifact checkerが明示的に許容する。現行artifactはmacOS arm64のclean実測で、Windowsの実コンソール制御イベント発生と3正式OSattestationは証明しない。Windows回帰は`TODO: node-interrupt-windows-console-test`として残し、`sync_compat_evidence.mjs --generate`は実測で`verified 0 / trace-confirmed-unattested 455 / unverified 72`を返した。

U08では`plugin-node-stdin`と`plugin-node-stdin-callback`を追加し、`標準入力取得時`・`尋`・`文字尋`・`標準入力全取得`の4 entryを、標準入力のraw取得、CRLF、EOF時の末尾改行なし部分行、同期callback drainという同一の実行境界で比較した。`native-node-stdin-lines`、`native-node-stdin-callback`、`native-node-stdin-all`をcleanなmacOS arm64で実行し、公式source・公式生成JavaScript・lnako Interpreter・LLVM AOT O0〜O3のstdout/stderr・終了結果を一致させ、`dispatch-coverage-evidence.json`へ38 fixture・1,737 site・326 native entryの監査結果を記録した。`native-node-stdin-all`は`A\n日本語\n`、行命令は末尾改行のない`abc\r\n41\nrest`、callbackは`A\r\nB`を使い、EOFで残る部分行も比較している。行fixtureの`標準入力全取得`でも末尾改行なしraw入力を確認する。現行artifactは3正式OSの外部署名attestationを含まず、QuickJSは対象外である。`sync_compat_evidence.mjs --generate`は実測で`verified 0 / trace-confirmed-unattested 459 / unverified 68`を返した。

U09では`plugin_node`の`自分IPアドレス取得`（`command-0759`）と`自分IPV6アドレス取得`（`command-0760`）を追加し、公式Nodeの[命令一覧](https://nadesi.com/v3/doc/index.php?plugin_node=&show=)と固定upstreamの[`plugin_node.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/src/plugin_node.mts#L1180-L1219)が利用する`os.networkInterfaces()`の形状を、`synthetic-v1` topologyとして公式source・公式生成JavaScript・lnako Interpreter・LLVM AOT O0へ同じ順序で供給した。内部アドレスとIPv6の`scopeid`を含めて公式Nodeのネットワーク表を再現するが、命令の結果はアドレス文字列だけに射影する。IPv4は`127.0.0.1`→`192.0.2.10`、IPv6は`::1`→`fe80::1234`→`2001:db8::10`となり、cleanな`54155f6191baa95dcc1c9a73b7ef32c9a95e54f9`でfocused native shardのO0〜O3とdispatch coverageの同一siteを確認した。coverageは39 fixture・1,743 site・328 native entryへ更新され、`sync_compat_evidence.mjs --generate`は`verified 0 / trace-confirmed-unattested 461 / unverified 66`を返す。fixtureの決定性は確認済みだが、実OSの列挙順、3正式OSの外部署名attestationは未完了であり、`TODO: node-network-cross-os-attestation`として残す。

U10では`plugin-node-http-callbacks`と`plugin-node-http-onerror`をloopback HTTP fixtureへ接続し、`AJAX送信時`、`AJAX受信時`、`GET送信時`、`POST送信時`、`POSTフォーム送信時`、`AJAX失敗時`の6 entryを明示catalog ID付きのdispatch siteへ昇格した。cleanな`b6b48f1c1ab7a9e5dde68ec20440ed82b9ce21cf`から生成したartifactで、公式source・公式生成JavaScript・lnako Interpreter・LLVM AOT O0のsuccess/failure、`対象`更新、callback順序、compile manifest、runtime traceを比較した。loopbackを使うため外部HTTP endpointは証明せず、`plugin-node-http-callbacks`の公式source／生成route差は`officialRoutesEquivalent: false`としてartifactへ残し、公式sourceを選択oracleにする。dispatch coverageは41 fixture・1,760 site・334 native entry、`sync_compat_evidence.mjs --generate`は`verified 0 / trace-confirmed-unattested 467 / unverified 60`を返した。3正式OSの外部署名attestation、U10全O0〜O3の外部証拠は未完了であり、`TODO: node-http-cross-os-attestation`として残す。

U11では`plugin-node-http-options-and-promises`へ`AJAX受信`の成功経路を追加し、`AJAX保障送信`、`HTTP保障取得`、`GET保障送信`、`POST保障送信`、`POSTフォーム保障送信`、`AJAX内容取得`、`AJAX受信`の7 entryを明示catalog ID付きのdispatch siteへ接続した。cleanな`17df1d1ad29d5a5252a1cf34c30b4060163f4012`からcanonical、coverage、expected-exit、static constant、global bindingのderived artifactを再生成し、公式source・公式生成JavaScript・lnako Interpreter・LLVM AOT O0の結果、Promise成功resolve、`対象`更新、event drain、compile manifest、runtime traceを比較した。dispatch coverageは42 fixture・1,798 site・342 native entry、`sync_compat_evidence.mjs --generate`は`verified 0 / trace-confirmed-unattested 474 / unverified 53`を返した。別の公式Node HTTP差分テストは11ケース・27命令、AOT O0〜O3の7ケースに成功した。Promiseのreject専用fixture、3正式OSの外部署名attestation、外部HTTP endpointは未完了であり、`TODO: node-http-cross-os-attestation`として残す。

U12では既存の`plugin-node-http-async-values`を既定dispatch監査へ追加し、`POST送信`、`POSTフォーム送信`、`AJAXテキスト取得`、`AJAX_JSON取得`、`AJAXバイナリ取得`の5 entryを明示catalog ID付きのdispatch siteへ接続した。cleanな`e2589cdd0c01505d7b9ef69dd681051bf6ac4177`から43 fixture・1,820 site・348 native entryのcoverage artifactを再生成し、同fixtureの22 dispatchについて公式source・公式生成JavaScript・lnako Interpreter・LLVM AOT O0のstdout/stderr hash、Interpreter/AOT trace、compile manifestを比較した。`AJAX_JSON取得`は通常のJSONと空bodyの2 site、他4 entryは1 siteずつで、`AJAXバイナリ取得`のArrayBuffer形状も値比較へ含める。`sync_compat_evidence.mjs --generate`は`verified 0 / trace-confirmed-unattested 479 / unverified 48`を返した。これはloopbackによる成功値の証拠であり、Promise reject専用fixture、外部HTTP endpoint、3正式OSの外部署名attestation、QuickJS標準命令証拠は未完了である。

U13では`plugin-node-http-discord`、`plugin-node-http-discord-file`、`plugin-node-http-discord-failure`を既定dispatch監査へ追加し、`DISCORD送信`（JSON successとHTTP 400を`エラー監視`で捕捉する期待失敗）と`DISCORDファイル送信`（multipartのcontent/file）を明示catalog ID付きsiteへ接続した。cleanな`03e6071374a968443bec83a4ae85cb27c66f8c2b`でfixture／監査生成器を固定し、46 fixture・1,826 site・350 native entryのcoverageを再生成した。3 fixtureは公式source・公式生成JavaScript・lnako Interpreter・LLVM AOT O0でstdout/stderr、Interpreter/AOT trace、compile manifestを比較し、Discord 2命令の3 site（success 2、expected failure 1）を確認した。別のNode HTTP差分テストは11ケース・27命令、AOT O0〜O3の7ケースに成功した。外部Discord endpointへは接続しておらず、3正式OSの外部署名attestation、QuickJS標準命令証拠、実Discord APIとの相互運用性は未完了である。

U14では`LINE送信`と`LINE画像送信`を、公式固定ソースの命令固有廃止メッセージへ合わせた。AOTの既存`line_notify_discontinued` opcodeは値を維持し、`LINE画像送信`には末尾追加の専用opcodeを割り当てて、2命令の失敗dispatchを別catalog IDへ安全に接続した。`plugin-node-http-line-message-discontinued-captured`と`plugin-node-http-line-image-discontinued-captured`は`エラー監視`で例外を捕捉し、公式source・公式生成JavaScript・lnako Interpreter・LLVM AOT O0の失敗dispatch 1 siteと本文を比較する。`c539af2`で実装・fixture・台帳を固定し、`0a2cb47`でcleanな48 fixture・1,830 site・352 native entryのcoverageを再生成した。別のNode HTTP差分テストは13ケース・27命令、AOT O0〜O3の9ケースに成功した。LINE APIへは接続しておらず、これはAPI廃止に対する意図的な制限であり、QuickJS標準命令証拠と3正式OSの外部署名attestationは未完了である。

## 証拠基盤の柱

89件を命令名だけで台帳へ付け替えない。次の4基盤を依存関係の柱として実装する。

### P0 — fixture policyとalternate oracle

fixtureごとに、成功終了だけでは表せない実行結果を明示する。

| policy | 用途 |
|---|---|
| `oracle: official-source` / `official-generated` | 公式CLIと公式生成JavaScriptの既知差を選択的に扱う |
| `generatedRouteUnavailable` | standalone生成時にplugin登録されない公式経路を明示する |
| `expectedExit` | `終了`、`プロセス終`、廃止APIなどの期待終了・期待エラーを証拠化する |
| `hostAdapter` | ブラウザ、Explorer、ネットワークなどの副作用をcapture環境へ置き換える |
| `archiveHelper` | 公式の7z command/callback routeを保持したfixture専用stored-ZIP helperで外部実行をhermetic化する |
| `catalogIds` | 同名異pluginの実catalog IDをfixtureから指定する |
| `resolution: explicit-catalog-id` | `unique-name`以外の安全な命令同定を明示する |
| `officialSourceExpectedDifference` | 公式sourceとgenerated routeの既知差を隠さず記録する |

`ambiguous-name`を名前だけで自動選択することは禁止する。

### P1 — explicit catalog identity

次の経路のすべてに、名前だけでなく`catalogId`、`plugin`、`sourceName`、`resolved route`を残す。

```text
semantic binding
  -> compile manifest
  -> Interpreter trace
  -> AOT attempt/result
  -> dispatch coverage site
  -> evidence.json
```

同名命令の昇格条件は次の四者一致とする。

```text
fixture.catalogIds[name]
= semantic catalog ID
= Interpreter catalog ID
= AOT manifest/runtime catalog ID
```

一致しないsiteは従来どおり`ambiguous-name`または`unverified`に残す。これが`終`、path alias、`plugin_datetime` 28 entryを扱う前提である。

### P2 — global binding evidence

裸のglobal参照や可変globalを関数dispatchへ偽装しない。`lnako.global-binding-evidence.v1`相当の証拠を、既存のstatic constant evidenceと同じ厳格さで追加する。

最低限、catalog ID、global binding/site ID、Interpreter read/write trace、AOT manifest、AOT read/write trace、公式source/generated比較、clean commit provenanceをartifactへ記録する。U04では`lnako.global-binding-evidence.v1`で可変globalのload/storeをbuiltin dispatchとは別namespaceで検査し、U05では`lnako.global-binding-evidence.v2`の複数binding形式でOS依存値のglobal readをcatalog ID別に検査する。catalogの型が`関数`でも、括弧なしの実行構文がglobal readとしてlowerされる場合は、関数dispatchの証拠と混同しない。

### P3 — compat-js evidence

`compat-js`の4件はnative dispatchへ混ぜない。既存の公式CLIと`lnako run --compat-js`の比較へ、operation種別（`eval`、lookup、call、method-call）、catalog ID、stable site ID、attempt/resultを記録する`lnako.compat-js-evidence.v1`を接続する。

## 89件の実装単位

下表の「完了後」は、共通完了条件を満たして台帳の`unverified`が想定数だけ減った場合の値である。P1やP2の基盤作業自体はentry数を減らさない。

| 単位 | 対象 | 件数 | 完了後 |
|---|---|---:|---:|
| U01 | `command-0065 エラー発生`、`command-0066 __DEBUG`。既存の監視内throwとdebug traceをcoverageへ接続し、未捕捉例外のU07とは分ける | 2 | 440 |
| U02 | `command-0057 ナデシコ`、`command-0058 ナデシコ続`。外側のdynamic dispatchを証拠化し、generated standalone差をP0で扱う | 2 | 442 |
| U03 | `0702 ブラウザ起動`、`0703 エクスプローラー起動`。OS別argvを本番経路で組み立て、最後の外部process生成だけhost adapterでcaptureする | 2 | 444 |
| U04 | `0709 ファイルコピーデフォルト動作`。`上書禁止`→`上書`→`overwrite`のglobal read/write/readをP2で記録する（完了） | 1 | 445 |
| U05 | `0731 デスクトップ`、`0732 マイドキュメント`、`0735 テンポラリフォルダ`。OS依存値を固定文字列にせず、host adapterとglobal readを記録する（完了） | 3 | 448 |
| U06 | `0741 解凍`、`0742 解凍時`、`0743 圧縮`、`0744 圧縮時`。hermeticな7z互換helperで本体とcallbackを実行し、ZIPの意味結果を比較する（完了） | 4 | 452 |
| U07 | `0746 プロセス終`、`0747 強制終了時`、`0748 終了`。終了直前のdispatch-result、terminal reason、`trace-end`をflushし、expected exitを証拠化する（完了） | 3 | 455 |
| U08 | `0754 標準入力取得時`、`0755 尋`、`0756 文字尋`、`0757 標準入力全取得`。固定stdin、EOF、callback drainを同じsiteで比較する（完了） | 4 | 459 |
| U09 | `0759 自分IPアドレス取得`、`0760 自分IPV6アドレス取得`。公式Nodeとlnakoへ同じnetwork topologyを供給し、順序・internal・IPv6 scopeを比較する（完了） | 2 | 461 |
| U10 | `0761 AJAX送信時`、`0762 AJAX受信時`、`0763 GET送信時`、`0764 POST送信時`、`0765 POSTフォーム送信時`、`0766 AJAX失敗時`。loopbackでsuccess/failure/callback orderを証拠化する（完了） | 6 | 467 |
| U11 | `0769 AJAX保障送信`〜`0775 AJAX受信`のPromise/保障系7件。成功resolve、`対象`更新、event drain完了後にtraceを閉じる（完了。reject専用fixtureは別TODO） | 7 | 474 |
| U12 | `0777 POST送信`〜`0781 AJAXバイナリ取得`のasync値5件。text、JSON、binary、formをloopbackで比較し、AOT byte buffer種別まで確認する（完了。JSON通常body／空bodyの2 siteを含む） | 5 | 479 |
| U13 | `0782 DISCORD送信`、`0783 DISCORDファイル送信`。外部Discordへ送らず、loopback transportでJSON、multipart、failureを比較する（完了。success 2 siteとHTTP 400期待失敗1 site） | 2 | 481 |
| U14 | `0784 LINE送信`、`0785 LINE画像送信`。成功ではなく廃止エラーが互換結果であることを`エラー監視`のexpected failure dispatchと公式固有本文で証拠化する（完了） | 2 | 483 |
| U15 | `0799 簡易HTTPサーバ起動時`〜`0804 簡易HTTPサーバ移動`。ephemeral port、実通信、response、callback完了、shutdown、trace-endを一体でcoverageへ接続する | 6 | 489 |
| U16 | `0061 終`、`0268 ファイル名抽出`、`0269 パス抽出`、`0722 ファイル名抽出`、`0723 パス抽出`、`0745 終`。system/nodeのrouteをfixtureで分離し、P1の明示IDで同定する | 6 | 495 |
| U17 | `plugin_datetime`明示routeのidentity基盤。明示importを`{catalogId, plugin, namespace, route}`として保持する。entry数は減らさない | 0（基盤） | 495 |
| U18 | `0807 元号データ`、`0808 今`〜`0818 先月`。固定clock・Asia/Tokyo・global bindingを明示plugin routeで比較する | 12 | 507 |
| U19 | `0819 曜日`、`0820 曜日番号取得`、`0821 UNIX時間変換`、`0822 UNIXTIME変換`、`0823 日時変換`。既存差分fixtureをexplicit routeへ分離する | 5 | 512 |
| U20 | `0824 和暦変換`。explicit `plugin_datetime` routeで公式の`sys.__v0.元号データ is not iterable`境界を実測し、system版の成功を流用しない | 1 | 513 |
| U21 | `0825 年数差`〜`0834 日時加算`。和暦エラーを含まない別explicit fixtureで10件の実routeを証拠化する | 10 | 523 |
| U22 | `0051 JS実行`、`0052 JSオブジェクト取得`、`0053 JS関数実行`、`0056 JSメソッド実行`。QuickJS/compat-js専用traceをP3で追加する | 4 | 527 |

U01〜U15は51件、U16は6件、U18〜U21は28件、U22は4件で合計89件となる。U17はU18〜U21の前提であり、二重計上しない。

## 実行順序

依存関係を固定し、各単位の完了ごとに証拠台帳を再生成する。

```text
P0 fixture policy / alternate oracle
  ├─ U01, U02
  ├─ U03
  ├─ U06, U07
  └─ U08～U15
P2 global binding evidence
  └─ U04, U05
P1 explicit catalog identity
  ├─ U16
  └─ U17
      ├─ U18
      ├─ U19
      ├─ U20
      └─ U21
P3 compat-js evidence
  └─ U22
```

実装上は、まず一意名nativeの残り15件（474→489）、次に同名異pluginの34件（489→523）、最後にcompat-jsの4件（523→527）を目安にする。ただし、実際のcatalog ID・route・oracle差が確認できない場合は件数を減らさず、失敗理由をfixture policyまたは`docs/COMPATIBILITY_QUIRKS.md`へ残す。

## 各単位の共通完了条件

1. 公式oracleの種類と、必要なら公式source/generatedの差が明示されている。
2. fixture source SHA-256が証拠へ固定されている。
3. catalog IDが`unique-name`または`explicit-catalog-id`で確定している。
4. Interpreterの同一site実行がtraceされている。
5. AOT O0の同一site attempt/resultがtraceされている。
6. compile manifestとruntime routeのcatalog ID・plugin・siteが一致している。
7. selected oracleとlnakoのstdout、stderr、終了結果または期待エラーが一致している。
8. evidence artifactがclean commit provenanceを指している。
9. `node tools/sync_compat_evidence.mjs --check`が成功し、想定外の件数減少がない。
10. dispatch/security checkerが成功している。
11. 3正式OSで再現できない値はhost adapterまたはOS差の比較規則が明示されている。

## 公式ドキュメントの説明不足・不具合候補の記録規則

公式の命令一覧だけでは一致順、型、初期値、失敗時、event loop、plugin登録境界が読み取れない場合がある。固定v3.7.24の公式sourceと実測結果を照合し、次のように分離して記録する。

- 公式command listへの固定commitリンクと、必要なsource行へのリンクを付ける。
- 公式CLI、公式生成JavaScript、lnako Interpreter、純LLVM AOT O0〜O3のどの経路を実測したかを書く。
- 公式の現在動作、lnakoの現在動作、意図的制限か未実装か、差分fixture ID、TODO識別子を同じ項目へ書く。
- 仕様上の注意や不具合候補を、標準的に期待される挙動として修正しない。互換性を意図した再現と安全制限を明記する。
- 未実測境界は「未確定」とし、`trace-confirmed`や`verified`へ昇格させない。

現在のHTTPサーバのquery境界はこの規則の実例である。公式は`duplicate=first&duplicate=last`を後勝ち、値なしを`"undefined"`、`raw=a=b`を`"a"`、`empty=`を空文字として扱う。`docs/COMPATIBILITY_QUIRKS.md`と`plugin-httpserver-all`へこの実測を記録し、lnakoのInterpreter/AOT実装と16リクエスト差分へ反映する。不正percent、複数`?`、multipartの壊れた入力など未収録の境界は別TODOのまま残す。

## 台帳・CI・リリースの扱い

各単位のローカル検証順は次のとおりとする。

```sh
zig build fmt-check
ZIG_GLOBAL_CACHE_DIR=/Users/sora/Repositories/soramikan/lnako/.zig-global-cache zig build test --summary all
node tools/sync_compat_evidence.mjs --check
node tools/check_compat_report.mjs --no-build
node tools/check_dispatch_trace_security.mjs --no-build
node tools/check_dispatch_attestation_security.mjs
node tools/check_tracked_dispatch_attestation_security.mjs
node tools/check_tracked_dispatch_attestation.mjs --offline
```

変更機能の公式差分と`check_dispatch_coverage.mjs`を追加し、artifactを再生成したときだけ台帳件数を更新する。CIは完了まで作業を停止しないが、次のpush前に直近完了runの失敗jobを確認し、失敗があれば原因を調査・修正してからpushする。

現在のworkflowは3正式OSを含む45 test jobs＋1 attestation jobで、macOSは同時実行上限を考慮して1 runあたり5 jobsに固定している。job分割による壁時計短縮の効果は、待ち時間、wall-clock、runner合計、macOS queueを別々に記録し、検証経路を削減した短縮とは扱わない。

89件が0になってもGoal完了ではない。3正式OSの単体・差分・AOT・QuickJS・fuzz回帰、benchmark JSON/Markdown、配布archive/checksum/SBOM、署名済み`v1.0.0`タグとGitHub Releaseがすべて揃うまで継続する。
