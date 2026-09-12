# Issue #27 / バイナリ対応ストリームI/Oとハンドル管理

低レイヤー命令群（Issue [#27](https://github.com/soramikan/lnako/issues/27)）の実装契約。機械可読な正本は
[`src/runtime/low_level_foundation.zig`](../../src/runtime/low_level_foundation.zig) と
[`src/runtime/low_level_io.zig`](../../src/runtime/low_level_io.zig) である。
[G0 Foundation](G0_FOUNDATION.md) が固定した型・エラー・capability・命名規則の上に実装する。

## 命令一覧

| 命令 | 引数 | 戻り値 | capability | 操作名 |
| --- | --- | --- | --- | --- |
| `ファイル開く(PATH, MODE)` | PATH: String、MODE: String（省略時 `"r"`） | Handle | `stream_file_io` | `open` |
| `ファイル閉じる(HANDLE)` | Handle | undefined | `stream_file_io` | `close` |
| `ファイルバイト読む(HANDLE, SIZE)` | Handle、SIZE: Number/BigInt | Bytes（0 byteはEOF） | `stream_file_io` | `read` |
| `ファイルバイト書く(HANDLE, BYTES)` | Handle、BYTES: Bytes（Buffer kind） | Number/BigInt（書込バイト数） | `stream_file_io` | `write` |
| `ファイル同期(HANDLE)` | Handle | undefined | `stream_file_io` | `fsync` |
| `ファイル切詰(HANDLE, SIZE)` | Handle、SIZE: Number/BigInt | undefined | `truncate` | `ftruncate` |

字句解析は動詞の送り仮名を落とすため、dispatch名は語幹（`ファイル開` 等）になる。
利用者が書く `ファイル開く`/`ファイル閉じる`/`ファイルバイト読む`/`ファイルバイト書く` は同一命令へ正規化される。
動的文字列実行（`ナデシコ`/`実行`）の互換のため、送り仮名付きの表記も同一命令として受ける。

## Handle

- OSのfdや`std.Io.File`はなでしこ値として公開しない。Handleは `TYPEOF` が `"object"` の不透明オブジェクト（辞書）である。
- 明示的な `ファイル閉じる` が必要である。GCはハンドルを自動closeせず、Runtime終了時に残ハンドルを閉じる。
- 同一性はオブジェクトのポインタで判定し、`Runtime/Host` のhandle tableと対応付ける。
  同じ形の辞書を手作りしてもtableに載らないため無効になる（G0の`HandleContract`）。
- `HandleId` は `index: u32`（bit 0〜31）と `generation: u32`（bit 32〜63）の組。closeしてもindexのgenerationは保持し、
  同一indexの再利用によるuse-after-closeを誤検出しない。
- close後・二重close・未登録ハンドルへの操作は portable code `EBADF`。

## ファイル開くのMODE

Node.js `fs.open` の文字列flagsを写す。`r`/`r+`/`w`/`w+`/`a`/`a+` に修飾子 `b`/`x`/`s` を組み合わせられる。
各文字は高々1回。`x` は生成系（`w`/`w+`/`a`/`a+`）でのみ有効。未知の文字や重複・不正な組み合わせは `EINVAL`。
`b` は互換用で無視する。`s` は同期open（POSIXでは open 時の `O_SYNC`、確認できない環境では `ENOTSUP`）。
`w` 系は生成＋切詰、`a` 系は生成＋append（POSIXでは open 時の `O_APPEND` で原子的に末尾へ書く。Windowsは seek フォールバック）。`a+` の読込位置は先頭。`r` 系は既存ファイルの読み出し。
数値flags（`O_RDONLY`等）はG0で未凍結のため受け付けない。

## 読み書き契約

- `ファイルバイト読む` は現在位置から最大SIZEバイトを読み、結果をBytesで返す。
  読み込みが0 byteのときをEOFとし、空Bytes（0 byte）を返す。SIZEを超えない範囲の部分読込はEOFではない。
  64KiB単位でchunked readし、要求サイズの巨大な先行確保をしない。
  OS readが要求chunk未満を返した時点でその部分結果を返し、続きを待たない。
- `ファイルバイト書く` はBytes（`ByteKind.buffer`）だけを受け付ける。String、`Uint8Array`、`ArrayBuffer` kindは暗黙変換せず `EINVAL`。
  実際に書いたバイト数を返す（Number、安全整数を超える場合はBigInt）。
- BytesはNUL、0x80〜0xff、不正UTF-8を無変換でround-tripする。

## 構造化エラー

失敗は文字列だけの例外に丸めない。G0の`error_object_keys` に従い、`code`/`nativeCode`/`operation`/`path`/`path2`/`message`/`capability` を持つ辞書を投げる。

- `code` は `PortableErrorCode`。`portableCodeForFailure` が `std.Io` の失敗をportable codeへ写す。
  写せない失敗は `EINVAL` へ丸める。
- `operation` は `open`/`close`/`read`/`write`/`fsync`/`ftruncate`。
- `path` は開くときに対象パス、それ以外は `null`。`nativeCode` と `path2` は現在 `null` とする。
- 捕捉時の `エラーメッセージ` には構造化エラー辞書が入る。`エラーメッセージ["code"]` 等で分岐する。
- 未捕捉時は既存の失敗文言（`message`）を `実行時エラー:` として出力する。

## capability

- `低レイヤー機能対応判定(NAME)`：`Capability` の既知IDと実装状況から判定する。未知IDは `false`。
  現在は `stream_file_io` と `truncate` が実装済みで、既知だが未実装のID（`termios` 等）は `false`。
  `stream_file_io` は open/close/read/write/sync のホスト実装が揃っているときだけ true。`truncate` は切詰 callback があるとき true。
- `低レイヤー機能一覧取得()`：既知IDの全集（真偽ではない）を返す。
- 未対応操作の実行は成功値や `false` を返さず、`code=ENOTSUP` と `capability` を入れた構造化エラーを投げる。

## Interpreter / AOT

同一 `.nako3` fixture を lnako Interpreter と AOT（O0〜O3）で実行し、stdout / stderr / 生成FS状態が一致する。
`nativeCode` と `message` はOS差を許すが、`code` と EOF/部分読込/無効ハンドルの意味は一致させる。

- Interpreter: `src/plugins/lowlevel.zig` が `plugin_lowlevel` としてdispatch。実OS I/Oは `src/host/state.zig` の `CliHost` が持つhandle tableを介す。
- AOT: `src/runtime/aot/low_level.zig` が `lnako_aot_builtin_call_site` からdispatch。handle tableはAOT `Runtime` が持ち、ハンドル値はGCのmark対象になる。
- 既存 `開`/`読`/`バイナリ読`/`保存` は変更しない。標準cnako 527件のカタログ（`builtin_catalog.zig`）も変更しない。
  新規命令は `low_level_foundation.extension_command_names` として解析器のbuiltin解決と `システム関数存在` にのみ追加する。

## テスト

- 単体: `low_level_foundation.zig` / `low_level_io.zig` / `plugins/lowlevel.zig` / `aot/low_level.zig`
- Interpreter integration: `src/runtime/interpreter/tests.zig` がNUL/不正UTF-8を含むバイナリをchunked copyで一致させる
- AOT integration: `src/runtime/aot/tests.zig` が同一fixtureをSHA-256一致まで検証する
- 手動oracle: `lnako run` と `lnako build -O0..O3` の構造化エラーと出力が一致する