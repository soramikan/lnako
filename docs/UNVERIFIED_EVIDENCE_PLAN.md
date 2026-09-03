# `unverified` 89件の証拠化計画（U26完了・U27 path回帰修正後）

## 目的と基準

この文書は、なでしこ3 v3.7.24（upstream `aa18c7e640523938c680958fe731418cc6f7a58f`）の標準cnako 527 entryについて、実装済み機能を過大評価せず、`compat/v3.7.24/evidence.json`の`unverified`を実行証拠へ接続するための計画である。89件の初期残件をU01〜U26へ分解し、2026-09-03のU26完了後は次の状態にある。

| 状態 | entry数 | 意味 |
|---|---:|---|
| `verified` | 0 | 3正式OSの署名付きattestationまで揃った現在HEADの証拠 |
| `trace-confirmed-unattested` | 527 | 公式差分、Interpreter/AOTまたはcompat-js trace、compile manifest等は揃うが、外部署名attestation前 |
| `unverified` | 0 | U22でQuickJS／`compat-js`専用traceを接続済み |

`native: 523`という分類、fixtureの存在、Interpreterだけの成功、artifactの生成は、AOT verifiedや`trace-confirmed-unattested`を意味しない。各単位を完了扱いにするのは、この文書の共通完了条件と台帳検査が同時に通った場合だけとする。U22の4 entryはこの一般則のAOT条件ではなく、専用QuickJS経路で成功結果とcatalog root siteを確認した`compat-js`証拠である。最終的な目標は、まず`trace-confirmed-unattested 527 / unverified 0`、その後に3正式OSの外部署名attestationを含む`verified`へ進むことである。

## 現在の進捗（2026-09-03）

U26完了後の正本は、`compat/v3.7.24/evidence.json`、`compat/v3.7.24/compat-js-evidence.json`、`compat/v3.7.24/dispatch-evidence.json`、`compat/v3.7.24/dispatch-coverage-evidence.json`である。compat-js artifactは9ケース（成功6、期待失敗3）と4 entryの24 direct root siteを記録し、native dispatch証拠とは別schema・別namespaceで扱う。成功ケースは公式sourceと`lnako run --compat-js`の正規化stdout・終了状態・signalを比較し、stderrはhashだけを保存する。期待失敗は失敗相当の確認だけを行い、partial traceをproof siteへ選択しない。

### U22以降の現行更新（U26完了後）

canonical dispatch artifactは現行の`dispatch-evidence.json`へ固定し、Interpreter 944 event、Node route 42 event、AOT manifest 946件・runtime 1,888 eventを記録する。coverageとexpected-exit、global/static constant、compat-jsの補助artifactも現行のclean provenanceで追跡している。`compat/v3.7.24/evidence.json`は`verified 0 / trace-confirmed-unattested 527 / unverified 0`を維持しており、coverageは227 fixture・4,477 site・426/523 native entry・424/492 unique nameを、純LLVM AOTの全件証明とは分けたunattested sampled coverageとして記録する。fixture inventoryは414件（AOT 312、Interpreter 112、QuickJS 9）である。ベンチマークは`benchmarks/results/latest.json`／`latest.md`へmacOS arm64・Zig 0.16.0・LLVM 22.1.8のInterpreter／AOT compile／AOT run結果を保存済みだが、Linux／Windowsを含む性能記録は未完了である。

U26では、Buffer・Uint8Array・ArrayBufferへ設定したcustom `__proto__`の辞書prototype chainをToPrimitiveへ接続した。`native-system-object-to-primitive-byte-prototype`で公式CLI・公式生成JavaScript・Interpreter・LLVM AOT O0〜O3の`toString`／`valueOf`解決を比較し、標準prototypeの合成methodをcustom overrideとして扱わない。prototype置換後の標準byte buffer property全体、receiver付きmethod、descriptorは`TODO: aot-byte-buffer-value`／`TODO: aot-buffer`へ分離する。fixture inventoryは414件（AOT 312、Interpreter 112、QuickJS 9）へ更新されたが、527 entryの証拠状態は変わらず`trace-confirmed-unattested 527 / unverified 0`である。

追加の互換境界として、固定v3.7.24の[`plugin_node.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/src/plugin_node.mts#L1401-L1423)にある`AJAX内容取得`の未知種別を`plugin-node-http-content-unknown-type`へ固定した。公式は未知種別で`Response.body`を`res.body()`として呼ぶため、外側の失敗callbackで観測される拒否理由は`TypeError: res.body is not a function`になる。lnakoはJavaScript runtimeを呼ばず、`InvalidAjaxContentType`をこの観測可能な拒否理由へ変換するだけで、未知種別を正常なbody取得として実装しない。さらに公式の[`AJAX受信`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/src/plugin_node.mts#L1426-L1447)が400応答で`対象`を変更せず`console.error`へ流す境界を`plugin-node-http-receive-error`へ固定し、lnakoもstderrへ観測可能な接頭辞とstatusを出す。公式CLI・lnako Interpreter・純LLVM AOT O0〜O3の15ケース（27命令、AOT 11ケース）を比較し、Interpreter／AOTの実行経路を同一fixtureへ接続した。これらの単位は既存の89件の証拠化件数を増減させず、通常dispatch coverageへ未検証のsiteを追加せず、公式sourceの不具合候補とNode内部stack差は`docs/COMPATIBILITY_QUIRKS.md`へ分離して記録する。対応するTODO `node-http-response-unknown-type`と`node-http-ajax-receive-error`は解消済みとするが、3正式OSの外部署名attestationは未完了である。

CIはjob増加とmacOS同時実行上限を考慮し、通常10 job、Linux/Windows専用parser fuzz 2 job、native AOT 27 job、Linux/Windows support AOT 12 jobの合計51 matrix job、coverage shard検証job、attestation jobへ分割した。macOSは1 runあたり5 jobを維持し、Linux/Windowsのdispatch coverageだけを3 weighted shardへ分ける。直近完了run `33691715529`ではmacOS `mac-core-standard-support`のbaseline検証が、リモートに未pushだった現行HEAD由来dispatch証拠を参照して失敗した。これは証拠生成物のpush順序の問題であり、実装・AOT実行・macOS 5枠の失敗ではない。証拠更新を同じ署名コミットへまとめてからpushし、次回push前にも完了済み失敗runを再確認する。壁時計・runner合計の改善値は成功した完了runで測定するまで未確定とする。待機中に作業は停止しない。

公式HTTPサーバqueryの異常系を、固定`plugin_httpserver.mts`の`decodeURIComponent`／`uri.split('?')`へ合わせた。`%`欠落・非16進・不正UTF-8は`URI malformed`、2個目以降の`?`は無視する。Interpreter/AOT単体テストと既存の公式HTTP差分を通過し、詳細は`docs/COMPATIBILITY_QUIRKS.md`へ記録した。この単位は`httpserver-query-parser-error`の未実装TODOを解消したもので、POSTフォームの`URLSearchParams`寛容性は変更していない。続くU23では、固定sourceのcase-sensitiveなmultipart content-type、boundary正規表現、LF-only header、引用付きContent-Dispositionの部分一致をInterpreter/AOTへ揃え、`plugin-httpserver-all`を21件から23件へ拡張した。壊れたbody全体の診断、外部endpoint、3正式OSのHTTP attestationは未確定のまま残す。

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

U15では`http-server-dispatch-cases.json`を追加し、`簡易HTTPサーバ起動時`、`簡易HTTPサーバ静的パス指定`、`簡易HTTPサーバ受信時`、`簡易HTTPサーバ出力`、`簡易HTTPサーバヘッダ出力`、`簡易HTTPサーバ移動`の6 entryを、ephemeral portへの外部loopback 7 requestへ接続した。`終了`はU07の既存expected-exit証拠をflushする補助命令として同じfixtureへ含めるが、新規6件には数えない。公式source・lnako Interpreter・LLVM AOT O0のHTTP response status/header/body hash、Interpreter/AOT trace、O0 compile manifestを比較し、coverageを49 fixture・1,849 site・359 native entryへ更新する。公式生成JavaScriptはshutdown補助命令`終了`をstandalone pluginへ登録できず、`TypeError: __self.__varslist[0].get(...) is not a function`になるため、公式sourceを選択oracleとする既知route差として記録する。同一プロセス内self-HTTPを避ける外部clientは、Interpreterのイベントポーリング順序によるdeadlockを避けるfixture設計であり、製品HTTP仕様の差ではない。これはmacOS arm64のdispatch証拠で、既存AOT O0〜O3差分、QuickJS、外部endpoint、3正式OS attestationを証明しない。`TODO: node-http-cross-os-attestation`は継続する。

U16では、公式の同名登録経路を名前だけで混同しないため、`tests/oracle/plugin-route-cases.json`へsystem-onlyの`plugin-system-path-route`／`plugin-system-end-route`とNode-onlyの`plugin-node-path-route`を追加した。`終`（`command-0061`）、system側の`ファイル名抽出`／`パス抽出`（`command-0268`／`command-0269`）、Node側の同名path命令（`command-0722`／`command-0723`）、Node側`終` alias（`command-0745`）の6 entryを、fixtureの`catalogIds`、semantic binding、Interpreter trace、AOT compile manifest/runtime traceの一致で明示同定した。system-onlyの公式生成JavaScriptはstandalone system plugin runtime bundleがないため実行不能として記録し、公式sourceを選択oracleとした。system routeでは`/a/b`のbasename／dirnameが`b`／`/a`、`a/`が空文字／`a`となり、`終`は`__終わる__`を`エラー監視`へ渡す。Node routeの`a/b.txt`は`b.txt`／`a`となる。cleanな`401af96726488588a31a252bbe1185de9298435d`から再生成したdispatch coverageは52 fixture・1,863 site・364 native entry（362 unique names）で、同期後の台帳は`verified 0 / trace-confirmed-unattested 495 / unverified 32`となった。これはmacOS arm64のclean実測であり、3正式OSの外部署名attestation、QuickJS、全527 entryの純LLVM AOT実行を意味しない。

### U27 — Windows path root-scan回帰の修正

push前の完了CI `33708609448`を再確認した結果、WindowsのAOT native shard 2/3（O0〜O3）で`native-node-path-mixed-separators`だけが失敗していた。公式source・公式generated・AOTは一致し、Interpreterだけが混在区切りnamespace pathのdirnameへ余分な`Z:_ab?0Y/`を残していたため、`src/plugins/node.zig`のWindows dirnameをAOTと同じNode 24相当のroot scanへ揃えた。これは意図的制限ではなく実装バグであり、公式仕様・実測・差分テストIDは`docs/COMPATIBILITY_QUIRKS.md`へ記録した。`f07e30d320339611730d3e563700a78b507a376d`からcanonical／coverage／補助artifactを再生成し、`dirty:false`とcommit一致を確認した。Windows targetのクロスビルドと全Zigテスト（837/837）は成功したが、修正commitのWindows runner外部署名attestationは次回CIで確認する。

## U17〜U26完了記録

U17〜U21では、`plugin_datetime`の同名命令を通常の`plugin_system` routeから流用せず、`plugin-datetime-clock-route`（`command-0808`〜`command-0818`）、`plugin-datetime-conversion-route`（`command-0819`〜`command-0823`）、`plugin-datetime-era-route`（`command-0824`）、`plugin-datetime-difference-addition-route`（`command-0825`〜`command-0834`）の4 fixtureへ分離した。`command-0807 元号データ`は`native-datetime-plugin-era-data`のstatic global readとして別artifactへ固定した。全28 entryでfixtureの`catalogIds`、`pluginRoute: plugin_datetime`、`expectedDispatchRoute`、Interpreter trace、AOT compile manifest/runtime traceを明示し、`sync_compat_evidence.mjs --generate`は`verified 0 / trace-confirmed-unattested 523 / unverified 4`を返す。

coverage artifactはcleanな`f92c76d6ed91bfc4738854be202bdbe48984d8c7`由来の56 fixture・1,917 site・391 native entry（492 unique names中389）で、fixture inventoryは410件（AOT 308、Interpreter 110、QuickJS 9）である。公式source import時の旧形式plugin警告はfixture宣言の`officialSourceStderrIncludes`だけを許容し、raw stderr hashを保持する。`和暦変換`は公式sourceの`sys.__v0.元号データ is not iterable`とgenerated routeの成功値を別route差として扱い、`日付加算`はplugin routeの`2024/02/29`とsystem routeの`2024/03/02`を区別する。これらは`trace-confirmed-unattested`であり、3正式OSの外部署名attestation後の`verified`ではない。

U22完了後の履歴監査では、`--include-native`を用いて当時のclean coverage artifactから225 fixture・4,464 site・426 native entry（492 unique names中424）を再実行し、未観測97 native entryを`unobservedNativeEntryIds`へ明示しました。同名命令はcatalog IDで解決し、公式generated routeが終了コード0でもstdoutだけ異なる場合は利用可能性とroute同値性を別metadataへ保存します。この拡張は初期89件の台帳状態（`trace-confirmed-unattested: 527`、`unverified: 0`）を変更せず、単一macOS環境のunattested sampled coverageを増やしたものとして扱います。3正式OSのAOT／QuickJS／fuzz実行、外部署名attestation、`verified`昇格は引き続き後続の完了条件です。

U23では、固定`plugin_httpserver.mts`のmultipart処理を再確認し、case-sensitiveな`multipart/form-data`判定、`boundary=`正規表現のquoted/unquoted分岐と`;`後続parameterの切り捨て、CRLF/LFのheader separator、引用付き`name`／`filename`の部分一致をInterpreter/AOTへ揃えた。公式CLI／Interpreterは23リクエスト、AOTはO0〜O3の各23リクエスト、Zig全体は832/832テストで成功した。`filename`だけのContent-Dispositionが`name`の部分一致でfield nameを得る挙動も、標準的なmultipart解釈へ補正せずfixtureと`docs/COMPATIBILITY_QUIRKS.md`へ記録した。壊れたbody全体の診断、外部endpoint、3正式OSのHTTP attestationは未確定のまま残す。

U24では、固定公式parserの廃止構文分岐（[`nako_parser3.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/core/src/nako_parser3.mts#L216-L220)、[`yTikuji`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/core/src/nako_parser3.mts#L673-L680)）を再実測し、`逐次実行`と`!非同期モード`を空文として消費しながら後続文を継続する非致命`legacy_deprecated`診断を実装した。公式の`logger.error`と終了成功の組合せを、Parserの成功判定では阻害せずCLI診断には表示する。これは旧構文をasyncへ復活させる変更ではなく、現行`ASYNC`／Promise経路へ移行するための互換境界である。`official-legacy-async-docs`は、カタログやplugin説明に残る旧参照の更新漏れ候補として継続する。

U25では、配布検証器をmanifest／SBOMに記録されたpayloadとの完全一致へ厳格化した。tar.gzはustar magic、regular-file type、header checksum、厳密なoctal size、2ブロック終端と余分な末尾byteを検査し、ZIPはEOCD、single-disk、UTF-8名、local/central header、CRC32、size、offsetを相互照合する。self-testはtar header改変、manifest外entry、tar終端改変、ZIP payload CRC改変を拒否する。macOS arm64のLLVM/LLD同梱実配布物も生成・検証に成功したが、これは3正式OS配布物、checksum／SBOMの公開、署名済み`v1.0.0` Releaseの完了を意味しない。

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
| `officialSourceStderrIncludes` | 公式sourceだけが出す既知診断をfixture宣言で検証する。raw stderr hashは保持し、宣言外のstderr差は拒否する |

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

U22では`tests/oracle/compat-js-cases.json`の9ケース（成功6、期待失敗3）を実行し、成功ケースの正規化stdout・終了状態・signalを比較した。4 entryの直接root IR call site 24件をmetadata-only traceへ接続し、期待失敗のpartial traceはproof siteへ選択しない。stderrはhashのみを保持し、source・引数・値・ポインタはartifactへ保存しない。これはInterpreter＋QuickJSの実行証拠であり、native dispatch・純LLVM AOT・外部署名attestationを代替しない。

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
| U17 | `plugin_datetime`明示routeのidentity基盤。明示importを`{catalogId, plugin, namespace, route}`として保持する（完了） | 0（基盤） | 495 |
| U18 | `0807 元号データ`、`0808 今`〜`0818 先月`。固定clock・Asia/Tokyo・global bindingを明示plugin routeで比較する（完了） | 12 | 507 |
| U19 | `0819 曜日`、`0820 曜日番号取得`、`0821 UNIX時間変換`、`0822 UNIXTIME変換`、`0823 日時変換`。既存差分fixtureをexplicit routeへ分離する（完了） | 5 | 512 |
| U20 | `0824 和暦変換`。explicit `plugin_datetime` routeで公式の`sys.__v0.元号データ is not iterable`境界を実測し、system版の成功を流用しない（完了） | 1 | 513 |
| U21 | `0825 年数差`〜`0834 日時加算`。和暦エラーを含まない別explicit fixtureで10件の実routeを証拠化する（完了） | 10 | 523 |
| U22 | `0051 JS実行`、`0052 JSオブジェクト取得`、`0053 JS関数実行`、`0056 JSメソッド実行`。QuickJS/compat-js専用traceをP3で追加する（完了。9ケース、24 direct root site） | 4 | 527 |

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

実装上は、U01〜U15で一意名nativeの残り15件（474→489）を接続し、U16で同名異pluginの6件（489→495）を明示catalog IDへ接続した。U17〜U21では`plugin_datetime`の28件（495→523）を、4つの明示route fixtureと1つのstatic global evidenceへ接続し、U22でcompat-jsの4件（523→527）を専用traceへ接続済みである。公式sourceの旧形式plugin警告は`officialSourceStderrIncludes`で明示検証し、`和暦変換`のsource/generated差と、dayjs互換の月末クランプ（`2024/02/29`）対system Dateのオーバーフロー（`2024/03/02`）、compat-jsの成功／期待失敗の境界を`docs/COMPATIBILITY_QUIRKS.md`へ記録した。現在は`unverified 0`だが、3正式OSの外部署名attestation、全527 entryの純LLVM AOT実行、benchmark、配布物、Releaseは未完了である。

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

現在のHTTPサーバのquery境界はこの規則の実例である。公式は`duplicate=first&duplicate=last`を後勝ち、値なしを`"undefined"`、`raw=a=b`を`"a"`、`empty=`を空文字として扱い、2個目以降の`?`を`uri.split('?')`の2番目の要素だけへ含める。不正なpercent escapeやdecode後の不正UTF-8は`URIError: URI malformed`になる。`docs/COMPATIBILITY_QUIRKS.md`、Interpreter/AOT単体テスト、`plugin-httpserver-all`の正常系21リクエストへこの境界を記録・反映した。multipartでは、公式のcase-sensitiveなcontent-type判定、quoted/unquoted boundaryの正規表現、boundary後続parameterの切り捨て、LF-only header separatorをInterpreter/AOTへ反映した。multipartの壊れた入力、外部endpoint、3正式OSのHTTP attestationは未確定の別境界として残す。文字列幅埋めでは、公式sourceの`for (i < A)`が`parseInt(A)`より前にあるため正の`Infinity`が非終了になることを固定ソースで確認し、lnakoの`StringPadWidthUnbounded`を意図的安全差異として記録した。

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

変更機能の公式差分と`check_dispatch_coverage.mjs`を追加し、artifactを再生成したときだけ台帳件数を更新する。CIは完了まで作業を停止しないが、次のpush前に直近完了runの失敗jobを確認し、失敗があれば原因を調査・修正してからpushする。U22のcompat-js checkerはこの台帳とは別artifactを検査し、nativeのAOT件数を水増ししない。

現在のworkflowは3正式OSを含む51 matrix jobs（通常10、parser fuzz 2、native 27、support 12）＋coverage shard検証job＋1 attestation jobで、macOSは同時実行上限を考慮して1 runあたり5 jobsに固定している。Linux/Windowsのsupport dispatch coverageだけを各3 weighted shardへ分割し、macOSは全件full artifactを生成する。job分割による壁時計短縮の効果は、待ち時間、wall-clock、runner合計、macOS queueを別々に記録し、検証経路を削減した短縮とは扱わない。次のpush前には直近完了runの失敗jobを確認し、実行中runの完了は待たずに作業を継続する。

3正式OSの性能・配布証拠は通常CIへ混ぜず、`.github/workflows/release.yml`のタグ／手動workflowで収集する。各OSのReleaseSafe compilerからbenchmark JSON/MarkdownとLLVM/LLD同梱archiveを生成し、aggregate jobでtargetの揃い、共通計測条件、archive sidecar、SPDX SBOM、`SHA256SUMS`を検証する。正式tagのpublishはannotated signed tag、同一source commitのCI成功、`build.zig.zon`のversion一致を前提とし、手動実行ではReleaseを公開しない。未実行のworkflow artifactを性能結果・配布物・Release完了とは扱わない。

89件が0になってもGoal完了ではない。3正式OSの単体・差分・AOT・QuickJS・fuzz回帰、benchmark JSON/Markdown、配布archive/checksum/SBOM、署名済み`v1.0.0`タグとGitHub Releaseがすべて揃うまで継続する。
