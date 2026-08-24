# ネイティブプラグインABI

`lnako_plugin_v1`は、C ABIを使ってなでしこ命令を動的ライブラリから登録するための公開境界です。
定義の正本は[`include/lnako_plugin_v1.h`](../include/lnako_plugin_v1.h)です。プラグインは通常の
`.dylib`、`.so`、`.dll`としてビルドし、なでしこソースから相対または絶対パスで取り込みます。

```nako3
!「./libsample.dylib」を取り込む
サンプル命令(1,2)を表示
```

## エントリと登録

動的ライブラリは次のシンボルを公開します。

```c
LNAKO_PLUGIN_EXPORT const lnako_plugin_descriptor_v1 *lnako_plugin_v1(void);
```

ローダーは`struct_size`と`abi_version`を先に検証し、`initialize`へ永続するhost表と初期化中だけ
有効なregistry表を渡します。命令登録には、UTF-8の命令名、助詞シグネチャ、最小・最大引数数、
`SYNC`または`ASYNC`、任意の`PURE`属性、呼び出し関数を指定します。同期と非同期を同時または両方未指定に
した登録、ネイティブ同士の重複名、標準命令名との衝突、未知のフラグ、不正UTF-8は拒否されます。

登録一覧は実行時に確定するため、ネイティブプラグインを直接取り込むモジュールでは、厳格モードでも未知の
命令呼び出しを動的解決へ残します。未知の変数は引き続き意味解析エラーで、実際に登録されなかった命令は
実行時に`UnknownCommand`になります。

`deinitialize`はライブラリを閉じる前に一度呼ばれます。プラグインは、`deinitialize`から戻る前に自分が
開始した全スレッドを停止してください。この間は未完了tokenとhost表がまだ有効です。その後、未完了tokenを
破棄し、命令ごとの`destroy`でcommand contextを破棄してからライブラリを閉じます。

## opaque値と所有権

`lnako_value_v1`の内部表現は公開しません。値種別の確認、Number変換、UTF-8、バイト列、配列、辞書は
host表を通して操作します。関数値は`call_function`、命令名は`call_command`でなでしこ実行器へ再入呼び出し
できます。BigIntは10進文字列で作成し、文字列はUTF-8境界で受け渡します。

- 命令の`arguments`は呼び出し中だけ有効なborrowed handleです。保持する場合は`value_retain`します。
- `make_*`、`array_get`、`dictionary_get`、`call_command`、`call_function`の結果はowned handleです。
- 同期命令が`result`へ設定したhandleはhostへ所有権を移します。
- `complete_async`が成功した場合も、結果handleの所有権をhostへ移します。
- 配列追加・辞書設定は値そのものをコンテナへ保持するため、呼び出し側は渡したhandleを解放できます。
- `get_utf8`はStringとBigInt、`get_bytes`はBytesだけを受け付けます。型変換は`get_number`、`get_boolean`等を
  明示的に使います。返されたポインタは元handleを解放するまで有効です。

値handleはlnakoのGCルートとして追跡されるため、循環配列、辞書、関数をプラグインが保持している間も回収
されません。一方、解放漏れはプラグイン側のリークになります。

## 非同期命令とスレッド

非同期命令には0でない`async_token`が渡されます。命令は`result`をNULLのまま`PENDING`を返し、完了時に
必ず一度だけ`complete_async`を呼びます。hostはこれをなでしこのPromiseへ接続し、イベントループ上で解決
または拒否します。`PENDING`と同時に設定された同期resultは誤使用としてhostが解放します。

`complete_async`だけは別スレッドから呼べます。それ以外のhost callbackと値操作は、命令を呼び出した
lnakoスレッドで行います。バックグラウンド処理へ渡す結果handleは、スレッド開始前に作成またはretainし、
完了成功時に所有権を移してください。未完了tokenを残したまま終了するとイベントループも終了できません。

## エラーと安全性

同期命令は`OK`または`ERROR`、非同期命令は`PENDING`、即時`OK`、即時`ERROR`を返せます。エラー結果に
文字列handleを渡すとPromise拒否理由として使われ、未指定時は`NativePluginCommandFailed`になります。
ABI不一致、エントリ欠落、ロード失敗、引数数不一致はlnako側の実行時診断になります。

ネイティブプラグインはlnakoプロセスと同じ権限で動作します。署名・ハッシュ・配布元を確認できない
ライブラリを取り込まないでください。クラッシュやメモリ破壊を隔離するsandbox ABIではありません。

現在、動的ABIはIR実行器を使う`lnako run`と`lnako test`へ接続済みです。LLVM AOT生成物からの動的ABI呼び出しは
LLVMランタイム統合の完了まで未対応で、暗黙に別実装へ置き換えません。
`lnako check`は静的検査中に任意のネイティブ初期化コードを実行せず、ライブラリの存在・ABIは`run` / `test`で
検証します。

## 検証

`tools/check_native_plugin_abi.mjs`は公開Cヘッダだけを使うfixtureを共有ライブラリとして生成し、全正式OSで
ロードします。8命令を通して、sync・async・pure属性、即時完了・拒否・別スレッド完了、例外終了時のworker join、
Number、BigInt、UTF-8、Buffer、配列、辞書、関数、標準命令ホストコール、PromiseとGCルートを検証します。

```sh
zig build native-plugin-fixture
node tools/check_native_plugin_abi.mjs
node tools/check_native_plugin_abi.mjs --release-safe
```
