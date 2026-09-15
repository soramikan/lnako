# 低レイヤー命令契約

Issue [#27](https://github.com/soramikan/lnako/issues/27)〜[#36](https://github.com/soramikan/lnako/issues/36) が追加する低レイヤー命令の、命令名・助詞・引数順・戻り値・エラー契約を固定する。機械可読な正本は [`catalog.json`](catalog.json)、型契約は [`G0_FOUNDATION.md`](G0_FOUNDATION.md) である。本書は各Issueが参照する人間向け一覧であり、`catalog.json` と矛盾する場合は `catalog.json` を優先する。

すべての命令は `plugin_lowlevel` に登録し、全OS・全lnako経路に同名で存在させる。未対応は実行時の構造化エラー `ENOTSUP` で機械判定する（[`G0_FOUNDATION.md`](G0_FOUNDATION.md) の unsupported の扱いを参照）。

## 型契約の要約

| 型 | 契約 |
| --- | --- |
| `bytes` | 既存のBytes（Buffer kind）。octet列を無変換で保持。Stringからの暗黙変換なし |
| `handle` | 不透明オブジェクト。Number/BigInt/OS fdではない。close後と二重closeは `EBADF` |
| `offset` | 位置。安全整数ならNumber、超過はBigInt。内部は `i64` |
| `size` | 大きさ。安全整数ならNumber、超過はBigInt。内部は `u64` |
| `timestamp` | ナノ秒。公開は常にBigInt。内部は `i128`。欠損は `null` |
| `mode` | 数値権限mode（0〜0o7777）。`u32` |
| `pid` | プロセスID。`u32` |
| `signal` | POSIX信号番号。`u32` |
| `stream` | 標準入力/標準出力/標準エラー出力の識別子。string |
| `encoding` | ハッシュ出力encoding（hexなど）。string |
| `stat` | ファイル詳細情報の辞書。時刻はナノ秒BigInt |
| `dirEntry` | ディレクトリentryの辞書。`name` と `type` |
| `waitResult` | プロセス終了の辞書。`exitCode` と `signal` |
| `ttySize` | 端末サイズの辞書。`rows` と `columns` |
| `fsInfo` | ファイルシステム情報の辞書 |
| `void` | 戻り値なし |
| `null` | null値（EOFなど） |

引数型は `catalog.json` の `parameterTypes`（プレースホルダ→型）と各命令の `paramTypes`（上書き）を正本とする。辞書のフィールドは `catalog.json` の `typeSchemas` を正本とする。本書の命令表で助詞が `-` のものは助詞なし（0引数）を意味する。

## エラー契約

- 失敗は構造化エラー（辞書）を投げる。分岐に使うのは `code` で、`message` は使わない。
- 有効な portable code は G0 で固定した17種のみ。本書の命令表の「エラー」はその命令が投げ得る code の上限である。
- 0 byte read はEOF。partial read（1 byte以上）はEOFではない。
- 二重close・close後操作・無効handleは `EBADF`。capability不足は `ENOTSUP`。

## 命令一覧

### Issue 27 バイナリ対応ストリームI/Oとハンドル管理

- `ファイル開く`（ll-file-open）助詞 `PATHをMODEで/PATHを`、戻り `handle`、capability `stream_file_io`、エラー ENOENT/EACCES/EISDIR/EINVAL/EMFILE/ENFILE/ENOTSUP
- `ファイル閉じる`（ll-file-close）助詞 `HANDLEを/HANDLEの`、戻り `void`、capability `stream_file_io`、エラー EBADF
- `ファイルバイト読む`（ll-file-read）助詞 `HANDLEをSIZEで/HANDLEからSIZEを`、戻り `bytes`、capability `stream_file_io`、エラー EBADF/EINVAL/ENOTSUP
- `ファイルバイト書く`（ll-file-write）助詞 `HANDLEをBYTESで/HANDLEへBYTESを`、戻り `number`、capability `stream_file_io`、エラー EBADF/EINVAL/ENOSPC/EPIPE/ENOTSUP
- `ファイル同期`（ll-file-sync）助詞 `HANDLEを/HANDLEの`、戻り `void`、capability `stream_file_io`、エラー EBADF/EINVAL
- `ファイル切詰`（ll-file-truncate-handle）助詞 `HANDLEをSIZEで/HANDLEをSIZEに`、戻り `void`、capability `truncate`、エラー EBADF/EINVAL/ENOSPC/ENOTSUP
- `ファイル位置変更`（ll-file-seek）助詞 `HANDLEをOFFSETでWHENCEを/HANDLEをOFFSETで`、戻り `offset`、capability `stream_file_io`、エラー EBADF/EINVAL/ENOTSUP
- `ファイル位置取得`（ll-file-tell）助詞 `HANDLEを/HANDLEの`、戻り `offset`、capability `stream_file_io`、エラー EBADF
- `ファイル位置指定読込`（ll-file-pread）助詞 `HANDLEをOFFSETからSIZEを/HANDLEからOFFSETにSIZEを`、戻り `bytes`、capability `stream_file_io`、エラー EBADF/EINVAL/ENOTSUP
- `ファイル位置指定書込`（ll-file-pwrite）助詞 `HANDLEへOFFSETにBYTESを/HANDLEをOFFSETからBYTESで`、戻り `number`、capability `stream_file_io`、エラー EBADF/EINVAL/ENOSPC/ENOTSUP

### Issue 28 Raw標準入出力とstdinサブシステム

- `標準入力バイト読む`（ll-stdin-read）助詞 `SIZEを/SIZEで`、戻り `bytes`、capability `raw_stdio`、エラー EINVAL/EPIPE
- `標準出力バイト書く`（ll-stdout-write）助詞 `BYTESを/BYTESで`、戻り `number`、capability `raw_stdio`、エラー EINVAL/EPIPE/ENOSPC
- `標準エラー出力バイト書く`（ll-stderr-write）助詞 `BYTESを/BYTESで`、戻り `number`、capability `raw_stdio`、エラー EINVAL/EPIPE/ENOSPC
- `標準出力同期`（ll-stdout-sync）助詞 `-`、戻り `void`、capability `raw_stdio`、エラー EPIPE/EINVAL
- `標準エラー出力同期`（ll-stderr-sync）助詞 `-`、戻り `void`、capability `raw_stdio`、エラー EPIPE/EINVAL

### Issue 29 stat/lstat・リンク・rename・unlink系

- `ファイル詳細情報取得`（ll-file-stat）助詞 `PATHを/PATHの/PATHから`、戻り `stat`、capability `stat`、エラー ENOENT/EACCES/ENOTDIR/ELOOP/EINVAL
- `シンボリックリンク情報取得`（ll-file-lstat）助詞 `PATHを/PATHの/PATHから`、戻り `stat`、capability `lstat`、エラー ENOENT/EACCES/ENOTDIR/ELOOP/EINVAL
- `シンボリックリンク作成`（ll-symlink-create）助詞 `TARGETをLINKへ/LINKにTARGETを`、戻り `void`、capability `symlink`、エラー EEXIST/ENOENT/EACCES/ENOTDIR/EPERM/ENOTSUP
- `シンボリックリンク先取得`（ll-symlink-read）助詞 `PATHを/PATHの`、戻り `string`、capability `readlink`、エラー EINVAL/ENOENT/EACCES/ELOOP/ENOTSUP
- `ハードリンク作成`（ll-hardlink-create）助詞 `TARGETをLINKへ/LINKにTARGETを`、戻り `void`、capability `hardlink`、エラー EEXIST/ENOENT/EXDEV/EPERM/ENOTSUP
- `実体パス取得`（ll-path-realpath）助詞 `PATHを/PATHの`、戻り `string`、capability `realpath`、エラー ENOENT/EACCES/ELOOP/ENOTDIR
- `パス名変更`（ll-path-rename）助詞 `SRCをDSTへ/DSTにSRCを`、戻り `void`、capability `rename`、エラー ENOENT/EEXIST/EACCES/EXDEV/ENOTEMPTY/EISDIR/ENOTDIR/ENOTSUP
- `ファイルリンク削除`（ll-path-unlink）助詞 `PATHを/PATHの`、戻り `void`、capability `unlink`、エラー ENOENT/EACCES/EPERM/EISDIR/ENOTDIR/ENOTSUP
- `空フォルダ削除`（ll-path-rmdir）助詞 `PATHを/PATHの`、戻り `void`、capability `rmdir`、エラー ENOENT/ENOTDIR/EACCES/ENOTEMPTY/EPERM/ENOTSUP

### Issue 31 ファイル時刻・truncate・高精度メタデータ更新

- `ファイルサイズ変更`（ll-file-truncate-path）助詞 `PATHをSIZEで/PATHをSIZEに`、戻り `void`、capability `truncate`、エラー ENOENT/EACCES/EISDIR/ENOSPC/EINVAL/ENOTSUP
- `ファイル時刻設定`（ll-file-utime-path）助詞 `PATHをATIMEからMTIMEまで/PATHをATIMEとMTIMEで`、戻り `void`、capability `utime`、エラー ENOENT/EACCES/EINVAL/EPERM/ENOTSUP
- `ファイル時刻設定済`（ll-file-utime-handle）助詞 `HANDLEをATIMEからMTIMEまで/HANDLEをATIMEとMTIMEで`、戻り `void`、capability `utime`、エラー EBADF/EINVAL/EPERM/ENOTSUP

`ATIME`/`MTIME` はナノ秒BigIntの引数で、`null` で既存値維持、`now` で現在時刻を表す。

### Issue 32 incremental hash

- `ハッシュ開始`（ll-hash-create）助詞 `ALGORITHMで/ALGORITHMを`、戻り `handle`、capability `incremental_hash`、エラー EINVAL/ENOTSUP
- `ハッシュ追加`（ll-hash-update）助詞 `HANDLEをBYTESで/HANDLEへBYTESを`、戻り `void`、capability `incremental_hash`、エラー EBADF/EINVAL
- `ハッシュ完了`（ll-hash-digest）助詞 `HANDLEをENCODINGで/HANDLEを`、戻り `hashDigest`、capability `incremental_hash`、エラー EBADF/EINVAL/ENOTSUP
- `ハッシュ破棄`（ll-hash-discard）助詞 `HANDLEを/HANDLEの`、戻り `void`、capability `incremental_hash`、エラー EBADF

`ENCODING` 省略時はraw bytes、`hex` 指定でhex文字列。完了後と破棄後の再操作は `EBADF`。アルゴリズム名の正規化は既存 `ハッシュ値計算` と同一。

### Issue 33 逐次ディレクトリ列挙

- `ディレクトリ開く`（ll-dir-open）助詞 `PATHを/PATHの`、戻り `handle`、capability `dir_iterator`、エラー ENOENT/ENOTDIR/EACCES/EMFILE/ENFILE/ENOTSUP
- `ディレクトリ次取得`（ll-dir-next）助詞 `HANDLEを/HANDLEの`、戻り `dirEntry`、capability `dir_iterator`、エラー EBADF/EINVAL/ENOTSUP
- `ディレクトリ閉じる`（ll-dir-close）助詞 `HANDLEを/HANDLEの`、戻り `void`、capability `dir_iterator`、エラー EBADF
- `ディレクトリ列挙時`（ll-dir-foreach）助詞 `PATHをCALLBACKで/PATHのCALLBACKを`、戻り `void`、capability `dir_iterator`、エラー ENOENT/ENOTDIR/EACCES/ENOTSUP

正本はhandle型。`. と .. は含めない。EOFは `null`。entryの `type` は file/directory/symlink/other/unknown。

### Issue 34 POSIX権限・所有者・UID/GID・access

- `ファイル権限設定`（ll-file-chmod）助詞 `PATHをMODEで/PATHをMODEに`、戻り `void`、capability `chmod`、エラー ENOENT/EACCES/EPERM/EINVAL/ENOTSUP
- `ファイル所有者設定`（ll-file-chown）助詞 `PATHをUIDとGIDで/PATHをUIDにGIDを`、戻り `void`、capability `chown`、エラー ENOENT/EACCES/EPERM/EINVAL/ENOTSUP
- `シンボリックリンク所有者設定`（ll-symlink-chown）助詞 `PATHをUIDとGIDで/PATHをUIDにGIDを`、戻り `void`、capability `chown`、エラー ENOENT/EACCES/EPERM/EINVAL/ENOTSUP
- `ファイルアクセス可能`（ll-file-access）助詞 `PATHをMODEで/PATHがMODEで`、戻り `boolean`、capability `access`、エラー EINVAL/ENOTSUP
- `UID取得`（ll-uid-get）助詞 `-`、戻り `uid`、capability `uid_gid`、エラー ENOTSUP
- `EUID取得`（ll-euid-get）助詞 `-`、戻り `uid`、capability `uid_gid`、エラー ENOTSUP
- `GID取得`（ll-gid-get）助詞 `-`、戻り `gid`、capability `uid_gid`、エラー ENOTSUP
- `EGID取得`（ll-egid-get）助詞 `-`、戻り `gid`、capability `uid_gid`、エラー ENOTSUP
- `所属グループID一覧取得`（ll-groups-get）助詞 `-`、戻り `array`、capability `uid_gid`、エラー ENOTSUP
- `UMASK変更`（ll-umask-set）助詞 `MODEで/MODEを`、戻り `number`、capability `uid_gid`、エラー ENOTSUP

数値modeのみを受け、symbolic mode（`u+x`）の解析はCore Utilities側で行う。`ファイルアクセス可能` はstatのmode-bit判定でなくOSのeffective access semanticsを使う。

### Issue 35 argv型プロセス起動・signal・priority・TTY

- `プロセス起動`（ll-process-spawn）助詞 `ARGVをOPTIONSで/ARGVを`、戻り `handle`、capability `argv_spawn`、エラー ENOENT/EACCES/EPERM/EINVAL/ENOTSUP
- `プロセス待機`（ll-process-wait）助詞 `HANDLEを/HANDLEの`、戻り `waitResult`、capability `argv_spawn`、エラー EBADF/EINVAL
- `プロセスID取得`（ll-pid-get）助詞 `-`、戻り `pid`、capability `argv_spawn`
- `親プロセスID取得`（ll-ppid-get）助詞 `-`、戻り `pid`、capability `argv_spawn`、エラー ENOTSUP
- `シグナル送信`（ll-signal-send）助詞 `PIDにSIGNALを/PIDへSIGNALで`、戻り `void`、capability `signal`、エラー EINVAL/EPERM/ENOTSUP
- `プロセス優先度取得`（ll-process-priority-get）助詞 `PIDを/PIDの`、戻り `number`、capability `priority`、エラー EINVAL/ENOTSUP
- `プロセス優先度設定`（ll-process-priority-set）助詞 `PIDをVALUEで/PIDをVALUEに`、戻り `void`、capability `priority`、エラー EINVAL/EPERM/ENOTSUP
- `端末判定`（ll-tty-isatty）助詞 `STREAMを/STREAMで`、戻り `boolean`、capability `tty_isatty`、エラー EINVAL
- `端末サイズ取得`（ll-tty-size）助詞 `STREAMを/STREAMで`、戻り `ttySize`、capability `tty_isatty`、エラー EINVAL/ENOTSUP

`プロセス起動` はshell文字列を介さずargv境界を保持する。`OPTIONS` に cwd / env / stdin・stdout・stderr（inherit/pipe/null）/ detached。`プロセス待機` の結果は `exitCode` と `signal` を分けて返す。

### Issue 36 statfs・reflink・sparse file

- `ファイルシステム情報取得`（ll-statfs）助詞 `PATHを/PATHの`、戻り `fsInfo`、capability `statfs`、エラー ENOENT/EACCES/ENOTDIR/EINVAL/ENOTSUP
- `ファイルクローン`（ll-reflink）助詞 `SRCをDSTへMODEで/SRCをDSTに`、戻り `void`、capability `reflink`、エラー ENOENT/EEXIST/EACCES/EXDEV/ENOTSUP
- `ファイルデータ領域検索`（ll-seek-data）助詞 `HANDLEをOFFSETで/HANDLEをOFFSETから`、戻り `offset`、capability `seek_data`、エラー EBADF/EINVAL/ENOTSUP
- `ファイル空洞領域検索`（ll-seek-hole）助詞 `HANDLEをOFFSETで/HANDLEをOFFSETから`、戻り `offset`、capability `seek_hole`、エラー EBADF/EINVAL/ENOTSUP
- `ファイル領域確保`（ll-fallocate）助詞 `HANDLEをOFFSETにSIZEで/HANDLEをOFFSETとSIZEで`、戻り `void`、capability `fallocate`、エラー EBADF/EINVAL/ENOSPC/ENOTSUP

### Issue 37 capability照会（メタ命令）

- `低レイヤー機能対応判定`（ll-capability-supported）助詞 `NAMEの/NAMEを`、戻り `boolean`
- `低レイヤー機能一覧取得`（ll-capability-list）助詞 `-`、戻り `array`

未知のNAMEは `false`。命令は全OS・全経路に登録するため、`システム関数存在` と組み合わせて未対応を判定する。

## 対応付け

- 各Issueの受け入れ条件を満たすoracleは [`TEST_HARNESS.md`](TEST_HARNESS.md) の共通基盤を使う。
- 既存 `plugin_node` 命令との重複・互換性方針は [`PLUGIN_NODE_COMPAT.md`](PLUGIN_NODE_COMPAT.md) を参照。