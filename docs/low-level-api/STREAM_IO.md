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
`w` 系は生成＋切詰、`a` 系は生成＋append（POSIXでは open 時の `O_APPEND` で原子的に末尾へ書く。Windowsは seek フォールバックのため、同一ファイルへの並行appendの原子性は保証しない）。`a+` の読込位置は先頭。`r` 系は既存ファイルの読み出し。
Windowsの末尾取得は `NtQueryInformationFile(FileStandardInformation)`（GetFileSizeEx相当）を使う。`FILE_ALL_INFORMATION` を問う stat系APIは `FILE_READ_ATTRIBUTES` を要求するため、書込み専用（`w`/`a` の `+` なし）ハンドルでは `STATUS_ACCESS_DENIED` になる。
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
  現在は `stream_file_io`、`truncate`、`utime`、`incremental_hash`（[HASH_IO.md](HASH_IO.md)）、`raw_stdio` が実装済みで、
  既知だが未実装のID（`termios` 等）は `false`。
  `stream_file_io` は open/close/read/write/sync のホスト実装が揃っているときだけ true。`truncate` はhandleのftruncateとpathのtruncateの両callbackが、`utime` はhandleのfutimensとpathのutimesの両callbackが揃っているときだけ true。`raw_stdio` は共有stdin source・raw出力・同期のホスト実装が揃っているときだけ true。
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

## Issue #28 / Raw標準入出力とstdinサブシステム

`cat`/`tee`/`head`/`wc` のような低レイヤーバイト処理を UTF-8検証・変換・NUL終端なしで行う命令群。
機械可読な正本は `low_level_foundation.zig` の `stdio_commands` と `catalog_commands`（`ll-stdin-*` / `ll-stdout-*` / `ll-stderr-*`）である。

## 命令一覧

| 命令 | 引数 | 戻り値 | capability | 操作名 |
| --- | --- | --- | --- | --- |
| `標準入力バイト読む(SIZE)` | SIZE: Number/BigInt | Bytes（0 byteはEOF） | `raw_stdio` | `read` |
| `標準出力バイト書く(BYTES)` | BYTES: Bytes（Buffer kind） | Number/BigInt（書込バイト数） | `raw_stdio` | `write` |
| `標準エラー出力バイト書く(BYTES)` | BYTES: Bytes（Buffer kind） | Number/BigInt（書込バイト数） | `raw_stdio` | `write` |
| `標準出力同期()` | なし | undefined | `raw_stdio` | `fsync` |
| `標準エラー出力同期()` | なし | undefined | `raw_stdio` | `fsync` |

## stdinの単一source of truth

- `StdinSource`（`low_level_io.zig`）が履歴buffer・`consumed`カーソル・EOF状態・下位chunk readerを持つ。
  所有はhost側（Interpreterは `CliHost`、AOTは `Runtime`）。plugin `Context` の `stdinSourceFn` /
  `peekStdinSourceFn` を介してnode系（`尋`/`文字尋`/`標準入力取得時`/`標準入力全取得`）と
  raw系（`標準入力バイト読む`）が同じ `consumed` カーソルを消費する。
- `標準入力全取得` は消費済みを含む全履歴を返す（upstream `__stdinRaw` と同じ）。cursorは動かさない。
- テキスト系命令（`尋`/`標準入力全取得`/`標準入力取得時`）の文字列化はlossy UTF-8で、
  不正UTF-8はU+FFFDへ置き換わる（upstream Nodeの `toString` と同じ）。InterpreterとAOTで共通。
  バイトをそのまま保存したい場合はraw系のBytesを使う。
- TTYの `尋` は直接行readを維持するが、共有sourceが生成済みならTTYでもsource経路を使う
  （直接readへ切り替えるとsourceにバッファ済みのバイトを置き去りにするため）。
  source経路ではEOF（TTYの `^D` 等）は粘着し、以後の行readは即 `""` を返す。
  これは共有cursorとupstreamのstream EOF意味論に整合する挙動である。
- `標準入力バイト読む` の1呼出しは1fillぶん（最大64KiB）まで返す。SIZEは上限ではなく
  「この呼出しで返す最大量」であり、部分読取りはEOFではない。0 byteの返却がEOF。
- `SIZE=0` はPOSIXの `read(fd, buf, 0)` と同じく空Bytesを返す。EOFフラグもcursorも
  動かさない（空Bytes自体はEOF時の0 byte返却と区別できない）。
- `StdinSource` の履歴は全取得契約のため消費済みも保持し、受信総量64MiBを上限とする
  （旧来のstdin slurp上限と同じ）。超過は `StreamTooLong` で、テキスト系命令は従来どおり
  一般エラー、raw系は `ENOSPC` の構造化エラーになる。

## raw出力と同期

- `標準出力バイト書く`/`標準エラー出力バイト書く` はテキスト表示経路（`表示`のwriterやlibc putchar
  バッファ）をflushしてからfdへ直接書き、実際に書けたバイト数を返す。空Bytesも合法。
- `標準出力同期`/`標準エラー出力同期` はテキスト側をflushしてからfdを `sync` する。
- NUL・0x80〜0xff・不正UTF-8は無変換でそのまま出入りする。
- 引数がBuffer kindのBytesでない場合（String/`Uint8Array`/`ArrayBuffer`等）は `EINVAL`。
- ホストがraw stdio callbackを提供しない場合は `ENOTSUP` に `capability=raw_stdio` を載せる。
  `低レイヤー機能対応判定("raw_stdio")` はcallbackが揃っているときだけ true。
