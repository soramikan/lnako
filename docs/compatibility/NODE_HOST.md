# Node・Hostのquirks

Node pluginの短い命令説明だけでは、引数型、OS差、外部tool、callback順序、公式generated routeの登録状態を判断できません。固定upstreamの [`plugin_node.mts`](https://github.com/kujirahand/nadesiko3/blob/aa18c7e640523938c680958fe731418cc6f7a58f/src/plugin_node.mts) と公式CLI／生成JavaScriptの実測を根拠にします。

## path引数の型

- 公式実測・source根拠: `ファイル名抽出`、`パス抽出`、`絶対パス変換`、`相対パス展開`は非文字列値を暗黙に文字列化せず、Node 24の引数ラベルと `TypeError` の `Received` 文面を返します。Windowsのnamespace pathやUNCはPOSIXと別規則です。
- lnakoの現在動作: nullish、number、boolean、BigInt、配列、object、function、Buffer、Uint8Array、ArrayBufferを型ごとに診断します。未検証のWindows特殊pathは推測実装しません。
- 判定: 仕様／未実装境界
- 対象経路: Interpreter / AOT
- 差分テストID: `native-node-path-type-errors`、`native-node-current-directory-error`
- TODO識別子: `TODO: node-path-win32-boundary`

## 標準入力のEOFと行分割

- 公式実測・source根拠: raw入力はCR/LFを保持し、行命令はCRLFのCRだけを除去します。EOFで末尾改行のない部分行も返し、callback命令は登録順に行を渡します。
- lnakoの現在動作: AOTでもstdinを一度バッファし、`尋` は数値化、`文字尋` は文字列のまま返します。`標準入力全取得` と全行callbackは同じraw入力境界を使います。
- 判定: 仕様
- 対象経路: Interpreter / AOT
- 差分テストID: `native-node-stdin-lines`、`native-node-stdin-callback`、`native-node-stdin-all`
- TODO識別子: なし

## ネットワークアドレス

- 公式実測・source根拠: `os.networkInterfaces()` は実行環境の列挙順、IPv4/IPv6、IPv6 `scopeid`を含むオブジェクト形状を返します。順序と実OSのinterface集合は固定仕様ではありません。
- lnakoの現在動作: deterministic fixtureでは `synthetic-v1` topologyを注入し、実OSの列挙を互換証拠へ混ぜません。実行時はOS APIから値を取得します。
- 判定: 再現性のための意図的制限
- 対象経路: Interpreter / AOT
- 差分テストID: `native-node-network-addresses`
- TODO識別子: `TODO: node-network-cross-os-attestation`

## HTTP callback・Promise

- 公式実測・source根拠: AJAX命令はsuccess/failure、`対象`の更新、callbackの登録・実行順、response bodyの種別、非2xx応答を別々に扱います。`AJAX内容取得` の未知種別で公式が `res.body is not a function` を返す不具合候補もあります。
- lnakoの現在動作: 純Zig HTTP clientとイベントqueueでcallback／Promiseをdrainし、`対象`更新とresponse本文・ArrayBuffer・form／JSONを処理します。loopbackを使い、外部endpointは証拠にしません。
- 判定: 仕様／公式バグ候補（未知種別）／再現性のための意図的制限
- 対象経路: Interpreter / AOT
- 差分テストID: `plugin-node-http-callbacks`、`plugin-node-http-options-and-promises`、`plugin-node-http-async-values`、`plugin-node-http-content-unknown-type`、`plugin-node-http-receive-error`
- TODO識別子: `TODO: node-http-cross-os-attestation`

## HTTP serverの登録とquery

- 公式実測・source根拠: 簡易HTTP serverはlistener、HTTP/1.1 parser、query/form/multipart、静的ファイル、response header、redirect、callback登録を組み合わせます。短い命令説明だけではquery decodeやcallback順序を決められません。
- lnakoの現在動作: 純Zig server routeとloopback clientを使い、query/form/multipart、静的file、header、redirectをfixtureで比較します。
- 判定: 仕様（fixtureで確定した範囲）
- 対象経路: Interpreter / AOT
- 差分テストID: `plugin-httpserver-all`、`compare_http_server_aot_oracle`
- TODO識別子: `TODO: httpserver-multipart-boundary`

## 7zと圧縮・解凍

- 公式実測・source根拠: 公式一覧は `7z` を前提にしますが、実行ファイルの存在やPATH上の可用性は保証しません。固定sourceは `a -r`、`x -o... -y`、tool path、callback順序を組み立てます。
- lnakoの現在動作: 既定経路はpure-Zig stored-ZIPで決定的に処理し、明示的なtool pathだけ外部7z互換toolへ委譲します。fixture専用helperは任意の外部7z実装やraw ZIP bytesを証明しません。
- 判定: 再現性のための意図的制限
- 対象経路: Interpreter / AOT
- 差分テストID: `plugin-node-native-archive-hermetic`、`check_node_archive_smoke`
- TODO識別子: `TODO: aot-node-archive-arbitrary-external-tool-diff`

## process・外部launcher

- 公式実測・source根拠: `起動`、`コマンド実行`、完了callback、`ブラウザ起動`、`エクスプローラー起動`はOS shell／launcherへ委譲します。OSやTTYによって副作用・終了順が変わります。
- lnakoの現在動作: processは純Zig adapterとイベントdrainで処理し、external launcherは安全なhost adapterで最終引数生成だけを検査します。実ブラウザや外部アプリの起動を差分証拠にしません。
- 判定: 意図的制限
- 対象経路: Interpreter / AOT
- 差分テストID: `plugin-node-process`、`plugin-node-process-order`、`plugin-node-process-completion-order`、`plugin-node-host-open-external`
- TODO識別子: `TODO: node-exit-cross-os-attestation`

## Windows path root scan

- 公式実測・source根拠: Windowsのdrive letter、root path、separatorの組み合わせはPOSIXの `/` 判定と異なります。root走査で同じpathを繰り返さない停止条件が必要です。
- lnakoの現在動作: volume rootを明示的に認識し、親pathが変化しない時点で走査を止めます。
- 判定: 意図的制限（無限走査防止）
- 対象経路: Interpreter / AOT
- 差分テストID: `native-node-path-mixed-separators`
- TODO識別子: なし

## LINE Notify廃止命令

- 公式実測・source根拠: 廃止されたLINE Notify命令は外部通信を行わず、公式側の廃止エラーへ到達します。
- lnakoの現在動作: Interpreter/AOTとも外部通信せず、廃止境界として診断を返します。成功経路のdispatch coverageには混ぜません。
- 判定: 意図的制限
- 対象経路: Interpreter / AOT
- 差分テストID: `plugin-node-line-message-discontinued`、`plugin-node-line-image-discontinued`
- TODO識別子: なし

## 公式generated JavaScriptの登録差

- 公式実測・source根拠: 一部pluginは公式CLI直接実行では登録されますが、standalone generated JavaScriptでは登録されず、呼出し時に `...is not a function` になる場合があります。これは公式sourceをoracleに選ぶ必要があるroute差です。
- lnakoの現在動作: 公式CLI相当のnative routeを実装し、generated routeの失敗を隠さずartifactへ記録します。公式の登録不足を新しい互換仕様として固定しません。
- 判定: 公式バグ候補
- 対象経路: Interpreter / AOT
- 差分テストID: `native-toml-imported-generated-route`、`native-caniuse-agents`
- TODO識別子: `TODO: node-http-generated-route-diagnosis`
